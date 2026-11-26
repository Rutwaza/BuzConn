/**
 * Admin panel backend. Every action is checked here (never trust the phone)
 * and written to `admin_events` (who, what, when).
 *
 * Roles (Firebase Auth custom claims):
 *   admin: true      owner. Everything, including adding/removing moderators.
 *   moderator: true  handles reports and suspends users. Cannot manage the
 *                    team or open the ghost archive.
 * Staff are also listed in `staff/{uid}` so the app can show the team and
 * moderation.js knows whom to alert about new reports.
 * Guide: README -> "Admin panel".
 */
const admin = require("firebase-admin");
const {onCall, HttpsError} = require("firebase-functions/v2/https");

const REGION = "us-central1";
// Temporary fallback until `node scripts/set-admin.js <email>` has run.
const OWNER_EMAILS = new Set(["nelsonjembe99@gmail.com"]);

const db = () => admin.firestore();
const now = () => admin.firestore.FieldValue.serverTimestamp();

function isAdmin(auth) {
  if (!auth) return false;
  if (auth.token.admin === true) return true;
  return auth.token.email_verified === true &&
    OWNER_EMAILS.has(String(auth.token.email || "").toLowerCase());
}

function isStaff(auth) {
  return isAdmin(auth) || auth?.token?.moderator === true;
}

function requireStaff(request) {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in first.");
  if (!isStaff(request.auth)) throw new HttpsError("permission-denied", "Admins and moderators only.");
}

function requireAdmin(request) {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in first.");
  if (!isAdmin(request.auth)) throw new HttpsError("permission-denied", "Admin only.");
}

async function log(request, type, data) {
  await db().collection("admin_events").add({
    type,
    ...data,
    byUid: request.auth.uid,
    byEmail: request.auth.token.email || null,
    at: now(),
  });
}

/** Suspend = sign-in blocked + logged out everywhere + profile marked inactive. */
async function setSuspended(uid, suspended) {
  await admin.auth().updateUser(uid, {disabled: suspended});
  if (suspended) await admin.auth().revokeRefreshTokens(uid);
  await db().collection("users").doc(uid).set({
    isActive: !suspended,
    suspended,
    updatedAt: now(),
  }, {merge: true});
}

/**
 * Deletes the reported post or status (with its likes/comments/views).
 * A copy is saved first in `evidence/{reportId}` (server-only, nobody can
 * read it from the app) so the police can still get it, e.g. for child
 * safety cases. Media files stay in R2.
 */
async function removeTarget(reportId, report, request) {
  const id = String(report.targetId || "");
  if (!id) return false;
  const path = {post: "posts", status: "statuses"}[report.targetType];
  if (!path) return false;
  const ref = db().collection(path).doc(id);
  const snap = await ref.get();
  if (snap.exists) {
    await db().collection("evidence").doc(reportId).set({
      reportId,
      reason: report.reason || null,
      targetType: report.targetType,
      targetPath: ref.path,
      content: snap.data(),
      savedBy: request.auth.token.email || request.auth.uid,
      savedAt: now(),
    });
  }
  await db().recursiveDelete(ref);
  return true;
}

/**
 * Handle one report.
 * data: {reportId, action: dismiss | remove | suspend | remove_and_suspend, note}
 */
exports.adminResolveReport = onCall({region: REGION}, async (request) => {
  requireStaff(request);
  const reportId = String(request.data?.reportId || "");
  const action = String(request.data?.action || "");
  const note = String(request.data?.note || "").slice(0, 500);
  if (!["dismiss", "remove", "suspend", "remove_and_suspend"].includes(action)) {
    throw new HttpsError("invalid-argument", "Unknown action.");
  }
  const ref = db().collection("reports").doc(reportId);
  const report = (await ref.get()).data();
  if (!report) throw new HttpsError("not-found", "Report not found.");

  const done = [];
  if (action === "remove" || action === "remove_and_suspend") {
    if (await removeTarget(reportId, report, request)) done.push("content removed (copy kept in evidence)");
  }
  if (action === "suspend" || action === "remove_and_suspend") {
    const uid = String(report.targetOwnerId || "");
    if (!uid) throw new HttpsError("failed-precondition", "This report has no user to suspend.");
    if (uid === request.auth.uid) throw new HttpsError("failed-precondition", "You cannot suspend yourself.");
    await setSuspended(uid, true);
    done.push("user suspended");
  }

  await ref.update({
    status: action === "dismiss" ? "dismissed" : "actioned",
    action,
    adminNote: note,
    handledBy: request.auth.token.email || request.auth.uid,
    handledAt: now(),
  });
  await log(request, "report_" + action, {reportId, targetType: report.targetType,
    targetId: report.targetId, targetOwnerId: report.targetOwnerId || null, note});
  return {ok: true, done};
});

/** data: {uid, suspended: true|false, note} */
exports.adminSetUserSuspended = onCall({region: REGION}, async (request) => {
  requireStaff(request);
  const uid = String(request.data?.uid || "");
  const suspended = request.data?.suspended === true;
  if (!uid) throw new HttpsError("invalid-argument", "uid is required.");
  if (uid === request.auth.uid) throw new HttpsError("failed-precondition", "You cannot suspend yourself.");
  const target = await admin.auth().getUser(uid);
  if (target.customClaims?.admin === true && !isAdmin(request.auth)) {
    throw new HttpsError("permission-denied", "Moderators cannot suspend an admin.");
  }
  await setSuspended(uid, suspended);
  await log(request, suspended ? "user_suspended" : "user_restored",
    {uid, note: String(request.data?.note || "").slice(0, 500)});
  return {ok: true};
});

/** Admin only. data: {email, role: "moderator" | "none"} */
exports.adminSetRole = onCall({region: REGION}, async (request) => {
  requireAdmin(request);
  const email = String(request.data?.email || "").trim().toLowerCase();
  const role = String(request.data?.role || "");
  if (!email || !["moderator", "none"].includes(role)) {
    throw new HttpsError("invalid-argument", "Give an email and role moderator or none.");
  }
  let user;
  try {
    user = await admin.auth().getUserByEmail(email);
  } catch (_) {
    throw new HttpsError("not-found", "No Duhuze account uses this email.");
  }
  if (user.customClaims?.admin === true) {
    throw new HttpsError("failed-precondition", "This is an admin account. Change admins with scripts/set-admin.js.");
  }
  const claims = {...(user.customClaims || {})};
  if (role === "moderator") claims.moderator = true;
  else delete claims.moderator;
  await admin.auth().setCustomUserClaims(user.uid, claims);
  const staffRef = db().collection("staff").doc(user.uid);
  if (role === "moderator") {
    await staffRef.set({uid: user.uid, email, role: "moderator", addedBy: request.auth.token.email || null, addedAt: now()});
  } else {
    await staffRef.delete();
  }
  await log(request, role === "moderator" ? "moderator_added" : "moderator_removed", {uid: user.uid, email});
  return {ok: true, uid: user.uid, note: "They must sign out and in again (or wait up to 1 hour)."};
});

// Verified badge for a real business page (admins only).
exports.adminSetVerified = onCall({region: REGION}, async (request) => {
  requireAdmin(request);
  const businessId = String(request.data?.businessId || "");
  const verified = request.data?.verified === true;
  if (!businessId) throw new HttpsError("invalid-argument", "businessId is required.");
  const ref = db().collection("businesses").doc(businessId);
  if (!(await ref.get()).exists) throw new HttpsError("not-found", "Page not found.");
  await ref.set({
    verified,
    verifiedAt: verified ? now() : null,
    verifiedBy: request.auth.uid,
  }, {merge: true});
  return {ok: true, verified};
});




// ------------------------------------------------------------- pages --

/** Suspend / restore a business page. A suspended page disappears from
 * feeds and search, its shop stops taking orders, and the owner can't edit
 * it or post as it until it is restored. data: {businessId, suspended, note} */
exports.adminSetPageSuspended = onCall({region: REGION}, async (request) => {
  requireStaff(request);
  const businessId = String(request.data?.businessId || "");
  const suspended = request.data?.suspended === true;
  const note = String(request.data?.note || "").slice(0, 500);
  const ref = db().collection("businesses").doc(businessId);
  const page = (await ref.get()).data();
  if (!businessId || !page) throw new HttpsError("not-found", "Page not found.");
  await ref.set({
    suspended,
    suspendedReason: suspended ? note : null,
    suspendedAt: suspended ? now() : null,
    updatedAt: now(),
  }, {merge: true});
  if (page.ownerId) {
    await notifyUser(page.ownerId, suspended ?
      `Your page "${page.name}" was suspended by the Duhuze team.${note ? " Reason: " + note : ""}` :
      `Your page "${page.name}" is active again.`, {businessId});
  }
  await log(request, suspended ? "page_suspended" : "page_restored", {businessId, note});
  return {ok: true};
});

/** Verified badge for a person. data: {uid, verified} (admins only). */
exports.adminSetUserVerified = onCall({region: REGION}, async (request) => {
  requireAdmin(request);
  const uid = String(request.data?.uid || "");
  const verified = request.data?.verified === true;
  if (!uid) throw new HttpsError("invalid-argument", "uid is required.");
  await db().collection("users").doc(uid).set({
    verified, verifiedAt: verified ? now() : null, verifiedBy: request.auth.uid,
  }, {merge: true});
  await log(request, verified ? "user_verified" : "user_unverified", {uid});
  return {ok: true};
});

/** A message from the team to one user (shows in their notifications). */
exports.adminWarnUser = onCall({region: REGION}, async (request) => {
  requireStaff(request);
  const uid = String(request.data?.uid || "");
  const message = String(request.data?.message || "").trim().slice(0, 500);
  if (!uid || message.length < 3) throw new HttpsError("invalid-argument", "Write a message.");
  await notifyUser(uid, `Message from the Duhuze team: ${message}`, {kind: "warning"});
  await log(request, "user_warned", {uid, message});
  return {ok: true};
});

/** Everything the team needs to judge one account. */
exports.adminUserDetails = onCall({region: REGION}, async (request) => {
  requireStaff(request);
  const uid = String(request.data?.uid || "");
  if (!uid) throw new HttpsError("invalid-argument", "uid is required.");
  const d = db();
  const count = async (q) => (await q.count().get()).data().count;
  let auth = null;
  try {
    const u = await admin.auth().getUser(uid);
    auth = {
      email: u.email || null, phone: u.phoneNumber || null, emailVerified: u.emailVerified,
      disabled: u.disabled, createdAt: u.metadata.creationTime, lastSignIn: u.metadata.lastSignInTime,
      providers: u.providerData.map((p) => p.providerId),
      admin: u.customClaims?.admin === true, moderator: u.customClaims?.moderator === true,
    };
  } catch (_) {/* deleted auth user */}
  const [posts, pages, followers, following, reportsAgainst, reportsActioned, orders] = await Promise.all([
    count(d.collection("posts").where("ownerId", "==", uid)),
    d.collection("businesses").where("ownerId", "==", uid).limit(20).get(),
    count(d.collection("user_follows").where("followingId", "==", uid)),
    count(d.collection("user_follows").where("followerId", "==", uid)),
    count(d.collection("reports").where("targetOwnerId", "==", uid)),
    count(d.collection("reports").where("targetOwnerId", "==", uid).where("status", "==", "actioned")),
    count(d.collection("orders").where("buyerId", "==", uid)),
  ]);
  return {
    auth, posts, followers, following, reportsAgainst, reportsActioned, orders,
    pages: pages.docs.map((p) => ({id: p.id, name: p.data().name || "Page",
      suspended: p.data().suspended === true, verified: p.data().verified === true})),
  };
});

/** Approve or reject a verification request. data: {requestId, approve, note} */
exports.adminReviewVerification = onCall({region: REGION}, async (request) => {
  requireAdmin(request);
  const requestId = String(request.data?.requestId || "");
  const approve = request.data?.approve === true;
  const note = String(request.data?.note || "").slice(0, 500);
  const ref = db().collection("verification_requests").doc(requestId);
  const req = (await ref.get()).data();
  if (!req) throw new HttpsError("not-found", "Request not found.");
  if (req.status !== "pending") throw new HttpsError("failed-precondition", "Already handled.");
  if (approve) {
    const target = req.kind === "page" ?
      db().collection("businesses").doc(req.targetId) :
      db().collection("users").doc(req.targetId);
    await target.set({verified: true, verifiedAt: now(), verifiedBy: request.auth.uid}, {merge: true});
  }
  await ref.update({status: approve ? "approved" : "rejected", reviewNote: note,
    reviewedBy: request.auth.token.email || request.auth.uid, reviewedAt: now()});
  await notifyUser(req.requesterId, approve ?
    `🎉 ${req.kind === "page" ? `Your page "${req.targetName}"` : "Your account"} is now verified ✓` :
    `Your verification request was not approved this time.${note ? " " + note : ""}`,
  {kind: "verification", targetId: req.targetId});
  await log(request, approve ? "verification_approved" : "verification_rejected",
    {requestId, kind: req.kind, targetId: req.targetId, note});
  return {ok: true};
});

/** One notification to everyone (admins only; up to 5000 people). */
exports.adminBroadcast = onCall({region: REGION, timeoutSeconds: 300}, async (request) => {
  requireAdmin(request);
  const message = String(request.data?.message || "").trim().slice(0, 300);
  if (message.length < 5) throw new HttpsError("invalid-argument", "Write the announcement.");
  const users = await db().collection("users").where("isActive", "==", true).limit(5000).get();
  const writer = db().bulkWriter();
  for (const u of users.docs) {
    writer.create(db().collection("notifications").doc(), notificationDoc(u.id, `📢 ${message}`, {kind: "announcement"}));
  }
  await writer.close();
  await log(request, "broadcast", {message, sent: users.size});
  return {sent: users.size};
});

exports.adminStats = onCall({region: REGION}, async (request) => {
  requireStaff(request);
  const count = async (q) => (await q.count().get()).data().count;
  const d = db();
  const since = (h) => admin.firestore.Timestamp.fromMillis(Date.now() - h * 3600000);
  const safe = (p) => p.catch(() => 0);
  const [users, pages, posts, openReports, urgentReports, suspended, suspendedPages,
    verifiedUsers, verifiedPages, pendingVerifications, orders, disputes,
    newUsers7d, newPosts24h, groups] = await Promise.all([
    count(d.collection("users")),
    count(d.collection("businesses")),
    count(d.collection("posts")),
    count(d.collection("reports").where("status", "==", "open")),
    count(d.collection("reports").where("status", "==", "open").where("reason", "==", "child_safety")),
    count(d.collection("users").where("suspended", "==", true)),
    count(d.collection("businesses").where("suspended", "==", true)),
    count(d.collection("users").where("verified", "==", true)),
    count(d.collection("businesses").where("verified", "==", true)),
    count(d.collection("verification_requests").where("status", "==", "pending")),
    count(d.collection("orders")),
    count(d.collection("orders").where("status", "==", "not_received")),
    safe(count(d.collection("users").where("createdAt", ">=", since(24 * 7)))),
    safe(count(d.collection("posts").where("createdAt", ">=", since(24)))),
    count(d.collection("chats").where("chatType", "==", "group")),
  ]);
  return {users, pages, posts, openReports, urgentReports, suspended, suspendedPages,
    verifiedUsers, verifiedPages, pendingVerifications, orders, disputes,
    newUsers7d, newPosts24h, groups};
});

function notificationDoc(toUserId, preview, extra = {}) {
  return {
    toUserId,
    fromUserId: "duhuze",
    fromUserName: "Duhuze team",
    fromUserImageUrl: null,
    type: "admin",
    preview,
    ...extra,
    readAt: null,
    hidden: false,
    createdAt: now(),
  };
}

async function notifyUser(uid, preview, extra) {
  if (!uid) return;
  await db().collection("notifications").add(notificationDoc(uid, preview, extra));
}

exports._adminInternals = {isAdmin, isStaff, notifyUser};
