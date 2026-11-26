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
const {FieldValue, Timestamp} = require("firebase-admin/firestore");

// The criteria. Shown in the app checklist and on duhuze-rw.web.app/guide.
// Change them here (and in the guide) only.
const RULES = {
  user: {minAccountDays: 30, minPosts: 3, minFollowers: 25},
  page: {
    minPageDays: 30, minOwnerDays: 30, minPosts: 6, minRecentPosts: 2, recentDays: 30,
    minFollowers: 50, minEngagement: 30, minRating: 3.5, minDescription: 30,
  },
  cleanDays: 90,
  // Old names, still read by older app versions.
  minAccountDays: 30, minPageDays: 30, minPosts: 3, minFollowers: 25,
};

const days = (ms) => Math.floor((Date.now() - ms) / 86400000);
const toMs = (t) => (t?.toMillis ? t.toMillis() : (typeof t === "number" ? t : 0));
const count = async (q) => (await q.count().get()).data().count;

async function recentStrikes(uid) {
  const since = Timestamp.fromMillis(Date.now() - RULES.cleanDays * 86400000);
  const snap = await db().collection("reports")
    .where("targetOwnerId", "==", uid).where("status", "==", "actioned").limit(20).get();
  return snap.docs.filter((d) => toMs(d.data().handledAt || d.data().createdAt) >= since.toMillis()).length;
}

/** Returns {eligible, checks:[{id,label,ok,detail}], targetName}. */
async function evaluate(uid, kind, targetId) {
  const checks = [];
  const add = (id, label, ok, detail, tip) =>
    checks.push({id, label, ok: !!ok, detail: detail || "", tip: tip || ""});
  const authUser = await admin.auth().getUser(uid);
  const user = (await db().collection("users").doc(uid).get()).data() || {};
  let targetName = user.name || "You";

  if (kind === "user") {
    const R = RULES.user;
    if (targetId !== uid) throw new HttpsError("permission-denied", "You can only ask for your own account.");
    if (user.verified === true) throw new HttpsError("already-exists", "You are already verified.");
    const age = days(Date.parse(authUser.metadata.creationTime));
    add("age", `Account at least ${R.minAccountDays} days old`, age >= R.minAccountDays, `${age} days`,
      "Keep using Duhuze: this one just needs time.");
    add("profile", "Profile photo, name and bio", user.imageUrl && user.name && String(user.bio || "").trim().length >= 10,
      "", "Edit profile: add a clear photo, your real name and a short bio.");
    add("contact", "Verified email or phone number", authUser.emailVerified || !!authUser.phoneNumber, "",
      "Confirm your email (check your inbox) or add a phone number.");
    const posts = await count(db().collection("posts").where("ownerId", "==", uid));
    add("posts", `At least ${R.minPosts} posts`, posts >= R.minPosts, `${posts} posts`, "Share a few posts.");
    const followers = await count(db().collection("user_follows").where("followingId", "==", uid));
    add("followers", `At least ${R.minFollowers} followers`, followers >= R.minFollowers, `${followers} followers`,
      "Share your profile link so people can follow you.");
  } else if (kind === "page") {
    const R = RULES.page;
    const page = (await db().collection("businesses").doc(targetId).get()).data();
    if (!page) throw new HttpsError("not-found", "Page not found.");
    if (page.ownerId !== uid) throw new HttpsError("permission-denied", "Only the page owner can ask.");
    if (page.verified === true) throw new HttpsError("already-exists", "This page is already verified.");
    targetName = page.name || "Page";
    add("pageActive", "Page is active (not hidden or suspended)", page.suspended !== true && page.isActive !== false);
    const age = days(toMs(page.createdAt));
    add("age", `Page at least ${R.minPageDays} days old`, age >= R.minPageDays, `${age} days`,
      "Pages need some history before they can be verified.");
    add("profile", "Logo, category and a real description",
      (page.imageUrl || page.logoUrl) && page.category &&
        String(page.description || "").trim().length >= R.minDescription,
      "", `Edit page: add a logo and a description of at least ${R.minDescription} letters.`);
    add("contact", "Phone number and location on the page", page.phone && (page.location || page.address), "",
      "Edit page: add a phone number and where you are.");
    const ownerAge = days(Date.parse(authUser.metadata.creationTime));
    add("owner", "Owner account: confirmed email or phone, 30+ days old",
      (authUser.emailVerified || !!authUser.phoneNumber) && ownerAge >= R.minOwnerDays,
      `${ownerAge} days`, "Confirm your email or add a phone number on your own account.");
    const postsSnap = await db().collection("posts").where("businessId", "==", targetId)
      .orderBy("createdAt", "desc").limit(60).get();
    const posts = await count(db().collection("posts").where("businessId", "==", targetId));
    add("posts", `At least ${R.minPosts} posts`, posts >= R.minPosts, `${posts} posts`, "Post more as the page.");
    const since = Date.now() - R.recentDays * 86400000;
    const recent = postsSnap.docs.filter((d) => toMs(d.data().createdAt) >= since).length;
    add("recent", `${R.minRecentPosts}+ posts in the last ${R.recentDays} days`, recent >= R.minRecentPosts,
      `${recent} recent`, "Keep the page active: post regularly.");
    const followers = await count(db().collection("page_follows").where("pageId", "==", targetId));
    add("followers", `At least ${R.minFollowers} followers`, followers >= R.minFollowers, `${followers} followers`,
      "Share the page link (Share -> Copy link) on WhatsApp and other places.");
    const engagement = postsSnap.docs.reduce((n, d) =>
      n + (Number(d.data().likeCount) || 0) + (Number(d.data().commentCount) || 0), 0);
    add("engagement", `Real people react: ${R.minEngagement}+ likes and comments`, engagement >= R.minEngagement,
      `${engagement} so far`, "Post things people like and answer comments.");
    const ratingCount = Number(page.ratingCount) || 0;
    if (ratingCount > 0) {
      const avg = Number(page.ratingAvg) || 0;
      add("rating", `Customer rating ${R.minRating}★ or more`, avg >= R.minRating,
        `${avg.toFixed(1)}★ from ${ratingCount}`, "Serve customers well; ask happy buyers to leave a review.");
    }
  } else {
    throw new HttpsError("invalid-argument", "kind must be user or page.");
  }
  add("standing", `Clean record: no suspension or removed content in ${RULES.cleanDays} days`,
    user.suspended !== true && (await recentStrikes(uid)) === 0, "",
    "Follow the community rules. This clears by itself after 90 days.");
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
