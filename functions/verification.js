/**
 * "Get verified" for people and pages.
 *
 * The app first calls `checkVerification` (shows a checklist), then
 * `requestVerification`, which checks the same rules again here (never
 * trust the phone) and puts a request in `verification_requests` for the
 * admins (Admin panel -> Verification).
 */
const admin = require("firebase-admin");
const {onCall, HttpsError} = require("firebase-functions/v2/https");

const REGION = "us-central1";
const db = () => admin.firestore();
const {FieldValue} = admin.firestore;

const RULES = {
  minAccountDays: 30,
  minPageDays: 14,
  minPosts: 3,
  minFollowers: 25,
  cleanDays: 90,
};

const days = (ms) => Math.floor((Date.now() - ms) / 86400000);
const toMs = (t) => (t?.toMillis ? t.toMillis() : (typeof t === "number" ? t : 0));
const count = async (q) => (await q.count().get()).data().count;

async function recentStrikes(uid) {
  const since = admin.firestore.Timestamp.fromMillis(Date.now() - RULES.cleanDays * 86400000);
  const snap = await db().collection("reports")
    .where("targetOwnerId", "==", uid).where("status", "==", "actioned").limit(20).get();
  return snap.docs.filter((d) => toMs(d.data().handledAt || d.data().createdAt) >= since.toMillis()).length;
}

/** Returns {eligible, checks:[{id,label,ok,detail}], targetName}. */
async function evaluate(uid, kind, targetId) {
  const checks = [];
  const add = (id, label, ok, detail) => checks.push({id, label, ok: !!ok, detail: detail || ""});
  const authUser = await admin.auth().getUser(uid);
  const user = (await db().collection("users").doc(uid).get()).data() || {};
  let targetName = user.name || "You";

  if (kind === "user") {
    if (targetId !== uid) throw new HttpsError("permission-denied", "You can only ask for your own account.");
    if (user.verified === true) throw new HttpsError("already-exists", "You are already verified.");
    const age = days(Date.parse(authUser.metadata.creationTime));
    add("age", `Account at least ${RULES.minAccountDays} days old`, age >= RULES.minAccountDays, `${age} days`);
    add("profile", "Profile photo, name and bio", user.imageUrl && user.name && String(user.bio || "").trim().length >= 10,
      "Add them in Edit profile");
    add("contact", "Verified email or phone number", authUser.emailVerified || !!authUser.phoneNumber);
    const posts = await count(db().collection("posts").where("ownerId", "==", uid));
    add("posts", `At least ${RULES.minPosts} posts`, posts >= RULES.minPosts, `${posts} posts`);
    const followers = await count(db().collection("user_follows").where("followingId", "==", uid));
    add("followers", `At least ${RULES.minFollowers} followers`, followers >= RULES.minFollowers, `${followers} followers`);
  } else if (kind === "page") {
    const page = (await db().collection("businesses").doc(targetId).get()).data();
    if (!page) throw new HttpsError("not-found", "Page not found.");
    if (page.ownerId !== uid) throw new HttpsError("permission-denied", "Only the page owner can ask.");
    if (page.verified === true) throw new HttpsError("already-exists", "This page is already verified.");
    targetName = page.name || "Page";
    add("pageActive", "Page is active (not suspended)", page.suspended !== true);
    const age = days(toMs(page.createdAt));
    add("age", `Page at least ${RULES.minPageDays} days old`, age >= RULES.minPageDays, `${age} days`);
    add("profile", "Logo, description and category",
      (page.imageUrl || page.logoUrl) && String(page.description || "").trim().length >= 20 && page.category,
      "Edit page to add them");
    add("contact", "Phone number and location", page.phone && (page.location || page.address));
    const posts = await count(db().collection("posts").where("businessId", "==", targetId));
    add("posts", `At least ${RULES.minPosts} posts`, posts >= RULES.minPosts, `${posts} posts`);
    const followers = await count(db().collection("page_follows").where("pageId", "==", targetId));
    add("followers", `At least ${RULES.minFollowers} followers`, followers >= RULES.minFollowers, `${followers} followers`);
  } else {
    throw new HttpsError("invalid-argument", "kind must be user or page.");
  }
  add("standing", "No suspension or removed content in the last 90 days",
    user.suspended !== true && (await recentStrikes(uid)) === 0);
  return {eligible: checks.every((c) => c.ok), checks, targetName};
}

function args(request) {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");
  const kind = String(request.data?.kind || "");
  const targetId = String(request.data?.targetId || (kind === "user" ? uid : ""));
  return {uid, kind, targetId};
}

exports.checkVerification = onCall({region: REGION}, async (request) => {
  const {uid, kind, targetId} = args(request);
  const result = await evaluate(uid, kind, targetId);
  const existing = await db().collection("verification_requests").doc(`${kind}_${targetId}`).get();
  return {...result, rules: RULES, request: existing.exists ?
    {status: existing.data().status, reviewNote: existing.data().reviewNote || ""} : null};
});

exports.requestVerification = onCall({region: REGION}, async (request) => {
  const {uid, kind, targetId} = args(request);
  const result = await evaluate(uid, kind, targetId);
  if (!result.eligible) {
    throw new HttpsError("failed-precondition", "Not eligible yet. Check the list.");
  }
  const ref = db().collection("verification_requests").doc(`${kind}_${targetId}`);
  const old = await ref.get();
  if (old.exists && old.data().status === "pending") return {status: "pending"};
  if (old.exists && old.data().status === "rejected" &&
      Date.now() - toMs(old.data().reviewedAt) < 30 * 86400000) {
    throw new HttpsError("failed-precondition", "You can ask again 30 days after a rejection.");
  }
  await ref.set({
    kind, targetId, targetName: result.targetName, requesterId: uid,
    note: String(request.data?.note || "").slice(0, 500),
    checks: result.checks, status: "pending",
    createdAt: FieldValue.serverTimestamp(),
  });
  return {status: "pending"};
});

exports._verificationInternals = {RULES};
