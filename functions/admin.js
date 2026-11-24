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

/** Small numbers for the dashboard. */
exports.adminStats = onCall({region: REGION}, async (request) => {
  requireStaff(request);
  const count = async (q) => (await q.count().get()).data().count;
  const d = db();
  const [users, pages, posts, openReports, urgentReports, suspended] = await Promise.all([
    count(d.collection("users")),
    count(d.collection("businesses")),
    count(d.collection("posts")),
    count(d.collection("reports").where("status", "==", "open")),
    count(d.collection("reports").where("status", "==", "open").where("reason", "==", "child_safety")),
    count(d.collection("users").where("suspended", "==", true)),
  ]);
  return {users, pages, posts, openReports, urgentReports, suspended};
});

exports._adminInternals = {isAdmin, isStaff};
