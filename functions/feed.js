/**
 * Phase 3: feed, reels, search and unread counts done on the server.
 *
 * - Every post gets `hasVideo` (for the Reels query) and `trendingScore`
 *   (for "For You", refreshed every 15 minutes).
 * - Following feed: when someone posts, the post id is copied into each
 *   follower's own list `timelines/{uid}/items/{postId}` ("fan-out on
 *   write"), so the app reads one short list instead of searching all posts.
 * - Search: users, pages and posts get `searchKeywords` (lowercase word
 *   beginnings), so the app can ask Firestore for matches directly.
 * - Unread badge: `users_private/{uid}.unreadNotifications` is a counter.
 */
const admin = require("firebase-admin");
const {
  onDocumentCreated, onDocumentUpdated, onDocumentDeleted, onDocumentWritten,
} = require("firebase-functions/v2/firestore");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const logger = require("firebase-functions/logger");

const REGION = "us-central1";
const FAN_OUT_LIMIT = 5000; // bigger accounts: followers' apps pull instead
const BACKFILL_ON_FOLLOW = 10;

const db = () => admin.firestore();
const FieldValue = admin.firestore.FieldValue;

// ---------------------------------------------------------------- helpers --

function toMillis(value) {
  if (!value) return Date.now();
  if (typeof value.toMillis === "function") return value.toMillis();
  if (value instanceof Date) return value.getTime();
  return Number(value) || Date.now();
}

function hasVideo(post) {
  if (Array.isArray(post.media) && post.media.some((m) => m && m.type === "video")) {
    return true;
  }
  return Boolean(post.videoUrl);
}

/**
 * "Hot" score, like Hacker News: engagement divided by age.
 * A fresh post with a few likes beats an old post with many.
 */
function trendingScore(post, now = Date.now()) {
  const ageHours = Math.max(0, (now - toMillis(post.createdAt)) / 3600000);
  const engagement =
    (Number(post.likeCount) || 0) * 1 +
    (Number(post.commentCount) || 0) * 2 +
    (Number(post.shareCount) || 0) * 3 +
    (Number(post.viewCount) || 0) * 0.05 +
    (Number(post.playCount) || 0) * 0.1;
  const mediaBonus = hasVideo(post) ? 1.5 : (Array.isArray(post.media) && post.media.length ? 0.5 : 0);
  const score = (1 + engagement + mediaBonus) / Math.pow(ageHours + 2, 1.5);
  return Math.round(score * 1e6) / 1e6;
}

/** Lowercase word beginnings: "Kigali Shoes" -> k, ki, kig, ... shoes. */
function keywordsFrom(...texts) {
  const out = new Set();
  for (const text of texts) {
    const words = String(text || "")
      .toLowerCase()
      .normalize("NFKD").replace(/[̀-ͯ]/g, "")
      .split(/[^a-z0-9@._]+/)
      .filter((w) => w.length >= 2)
      .slice(0, 30);
    for (const word of words) {
      const clean = word.replace(/^[@._]+|[@._]+$/g, "");
      for (let i = 2; i <= Math.min(clean.length, 15); i++) {
        out.add(clean.slice(0, i));
      }
      if (out.size >= 200) break;
    }
  }
  return [...out].slice(0, 200);
}

function sameArray(a, b) {
  if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;
  return a.every((v, i) => v === b[i]);
}

async function followerIdsOf(post) {
  const ids = new Set();
  const ownerId = String(post.ownerId || "");
  if (ownerId) {
    const snap = await db().collection("user_follows")
      .where("followingId", "==", ownerId).limit(FAN_OUT_LIMIT).get();
    snap.docs.forEach((d) => ids.add(String(d.data().followerId || "")));
  }
  const pageId = String(post.businessId || "");
  if (pageId) {
    const snap = await db().collection("page_follows")
      .where("pageId", "==", pageId).limit(FAN_OUT_LIMIT).get();
    snap.docs.forEach((d) => ids.add(String(d.data().followerId || "")));
  }
  ids.delete("");
  if (ownerId) ids.add(ownerId); // you see your own posts in Following too
  return [...ids];
}

function timelineItem(postId, post) {
  return {
    postId,
    ownerId: String(post.ownerId || ""),
    businessId: String(post.businessId || ""),
    createdAt: post.createdAt || FieldValue.serverTimestamp(),
  };
}

// ------------------------------------------------------------------ posts --

exports.onPostCreatedFeed = onDocumentCreated(
  {region: REGION, document: "posts/{postId}", timeoutSeconds: 300},
  async (event) => {
    const post = event.data?.data();
    if (!post) return;
    const {postId} = event.params;

    await event.data.ref.update({
      hasVideo: hasVideo(post),
      trendingScore: trendingScore(post),
      searchKeywords: keywordsFrom(post.businessName, post.content),
    });

    // Fan-out to followers' timelines.
    const followers = await followerIdsOf(post);
    const writer = db().bulkWriter();
    const item = timelineItem(postId, post);
    for (const uid of followers) {
      writer.set(db().collection("timelines").doc(uid)
        .collection("items").doc(postId), item);
    }
    await writer.close();
    logger.info("Post fanned out", {postId, followers: followers.length});
  },
);

// Keep hasVideo/searchKeywords right when the owner edits a post.
exports.onPostEditedFeed = onDocumentUpdated(
  {region: REGION, document: "posts/{postId}"},
  async (event) => {
    const before = event.data?.before?.data() || {};
    const after = event.data?.after?.data() || {};
    if (before.content === after.content &&
        before.businessName === after.businessName &&
        JSON.stringify(before.media || []) === JSON.stringify(after.media || []) &&
        before.videoUrl === after.videoUrl) {
      return; // counters/scores changed: nothing to do (and no loop)
    }
    const update = {};
    const video = hasVideo(after);
    if (after.hasVideo !== video) update.hasVideo = video;
    const keywords = keywordsFrom(after.businessName, after.content);
    if (!sameArray(after.searchKeywords, keywords)) update.searchKeywords = keywords;
    if (Object.keys(update).length) await event.data.after.ref.update(update);
  },
);

// Every 15 minutes: refresh "For You" scores of posts from the last 7 days.
exports.refreshTrendingScores = onSchedule(
  {region: REGION, schedule: "every 15 minutes", timeoutSeconds: 300},
  async () => {
    const since = admin.firestore.Timestamp.fromMillis(Date.now() - 7 * 24 * 3600000);
    const snap = await db().collection("posts")
      .where("createdAt", ">=", since).orderBy("createdAt", "desc").limit(3000).get();
    const now = Date.now();
    const writer = db().bulkWriter();
    let changed = 0;
    for (const doc of snap.docs) {
      const post = doc.data();
      const score = trendingScore(post, now);
      if (Math.abs((Number(post.trendingScore) || 0) - score) > 1e-6) {
        writer.update(doc.ref, {trendingScore: score});
        changed += 1;
      }
    }
    await writer.close();
    logger.info("Trending scores refreshed", {checked: snap.size, changed});
  },
);

// ---------------------------------------------------------------- follows --

async function backfillTimeline(followerId, field, value) {
  const posts = await db().collection("posts")
    .where(field, "==", value).orderBy("createdAt", "desc")
    .limit(BACKFILL_ON_FOLLOW).get()
    .catch(async () =>
      // If the composite index is still building, take any recent ones.
      db().collection("posts").where(field, "==", value).limit(BACKFILL_ON_FOLLOW).get());
  const batch = db().batch();
  posts.docs.forEach((doc) => {
    batch.set(db().collection("timelines").doc(followerId)
      .collection("items").doc(doc.id), timelineItem(doc.id, doc.data()));
  });
  await batch.commit();
}

async function removeFromTimeline(followerId, field, value) {
  const items = await db().collection("timelines").doc(followerId)
    .collection("items").where(field, "==", value).limit(500).get();
  const batch = db().batch();
  items.docs.forEach((doc) => batch.delete(doc.ref));
  await batch.commit();
}

exports.onUserFollowTimeline = onDocumentWritten(
  {region: REGION, document: "user_follows/{followId}"},
  async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    if (after && !before) {
      await backfillTimeline(String(after.followerId), "ownerId", String(after.followingId));
    } else if (before && !after) {
      await removeFromTimeline(String(before.followerId), "ownerId", String(before.followingId));
    }
  },
);

exports.onPageFollowTimeline = onDocumentWritten(
  {region: REGION, document: "page_follows/{followId}"},
  async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    if (after && !before) {
      await backfillTimeline(String(after.followerId), "businessId", String(after.pageId));
    } else if (before && !after) {
      await removeFromTimeline(String(before.followerId), "businessId", String(before.pageId));
    }
  },
);

// ------------------------------------------------------- search keywords --

exports.userSearchKeywords = onDocumentWritten(
  {region: REGION, document: "users/{uid}"},
  async (event) => {
    const after = event.data?.after?.data();
    if (!after) return;
    const keywords = keywordsFrom(after.name, after.username);
    if (!sameArray(after.searchKeywords, keywords)) {
      await event.data.after.ref.update({searchKeywords: keywords});
    }
  },
);

exports.pageSearchKeywords = onDocumentWritten(
  {region: REGION, document: "businesses/{pageId}"},
  async (event) => {
    const after = event.data?.after?.data();
    if (!after) return;
    const keywords = keywordsFrom(after.name, after.category, after.location, after.address);
    if (!sameArray(after.searchKeywords, keywords)) {
      await event.data.after.ref.update({searchKeywords: keywords});
    }
  },
);

// ---------------------------------------------------------- unread badge --

function unreadRef(uid) {
  return db().collection("users_private").doc(String(uid));
}

exports.countNotificationCreated = onDocumentCreated(
  {region: REGION, document: "notifications/{id}"},
  async (event) => {
    const n = event.data?.data();
    if (!n || n.readAt || n.hidden === true || !n.toUserId) return;
    await unreadRef(n.toUserId).set(
      {unreadNotifications: FieldValue.increment(1)}, {merge: true});
  },
);

exports.countNotificationUpdated = onDocumentUpdated(
  {region: REGION, document: "notifications/{id}"},
  async (event) => {
    const before = event.data?.before?.data() || {};
    const after = event.data?.after?.data() || {};
    const wasUnread = !before.readAt && before.hidden !== true;
    const isUnread = !after.readAt && after.hidden !== true;
    if (wasUnread === isUnread || !after.toUserId) return;
    await unreadRef(after.toUserId).set(
      {unreadNotifications: FieldValue.increment(isUnread ? 1 : -1)}, {merge: true});
  },
);

exports.countNotificationDeleted = onDocumentDeleted(
  {region: REGION, document: "notifications/{id}"},
  async (event) => {
    const n = event.data?.data();
    if (!n || n.readAt || n.hidden === true || !n.toUserId) return;
    await unreadRef(n.toUserId).set(
      {unreadNotifications: FieldValue.increment(-1)}, {merge: true});
  },
);

// ------------------------------------------- one-time backfill (Phase 3) --
// Runs every 10 minutes until `_maintenance/phase3.done == true`, then does
// nothing. Delete it after that.
exports.phase3Maintenance = onSchedule(
  {region: REGION, schedule: "every 10 minutes", timeoutSeconds: 540},
  async () => {
    const stateRef = db().collection("_maintenance").doc("phase3");
    const state = (await stateRef.get()).data() || {};
    if (state.done === true) return;
    const step = state.step || "posts";
    const last = String(state.last || "");
    const id = admin.firestore.FieldPath.documentId();
    const now = Date.now();
    const writer = db().bulkWriter();
    let next = {step, last};

    if (step === "posts") {
      const snap = await db().collection("posts").orderBy(id).startAfter(last).limit(300).get();
      for (const doc of snap.docs) {
        const post = doc.data();
        writer.update(doc.ref, {
          hasVideo: hasVideo(post),
          trendingScore: trendingScore(post, now),
          searchKeywords: keywordsFrom(post.businessName, post.content),
        });
      }
      next = snap.size ? {step, last: snap.docs.at(-1).id} : {step: "users", last: ""};
    } else if (step === "users" || step === "businesses") {
      const snap = await db().collection(step).orderBy(id).startAfter(last).limit(300).get();
      for (const doc of snap.docs) {
        const d = doc.data();
        const keywords = step === "users" ?
          keywordsFrom(d.name, d.username) :
          keywordsFrom(d.name, d.category, d.location, d.address);
        writer.update(doc.ref, {searchKeywords: keywords});
      }
      next = snap.size ? {step, last: snap.docs.at(-1).id} :
        (step === "users" ? {step: "businesses", last: ""} : {step: "timelines", last: ""});
    } else if (step === "timelines") {
      // Fill each user's Following timeline from who they already follow.
      const follows = await db().collection("user_follows").orderBy(id).startAfter(last).limit(100).get();
      for (const f of follows.docs) {
        const d = f.data();
        await backfillTimeline(String(d.followerId), "ownerId", String(d.followingId)).catch(() => {});
      }
      next = follows.size ? {step, last: follows.docs.at(-1).id} : {step: "pageTimelines", last: ""};
    } else if (step === "pageTimelines") {
      const follows = await db().collection("page_follows").orderBy(id).startAfter(last).limit(100).get();
      for (const f of follows.docs) {
        const d = f.data();
        await backfillTimeline(String(d.followerId), "businessId", String(d.pageId)).catch(() => {});
      }
      next = follows.size ? {step, last: follows.docs.at(-1).id} : {step: "unread", last: ""};
    } else if (step === "unread") {
      // Start every badge counter from the real number once.
      const users = await db().collection("users").orderBy(id).startAfter(last).limit(100).get();
      for (const u of users.docs) {
        const count = await db().collection("notifications")
          .where("toUserId", "==", u.id).where("readAt", "==", null).count().get();
        writer.set(unreadRef(u.id), {unreadNotifications: count.data().count}, {merge: true});
      }
      next = users.size ? {step, last: users.docs.at(-1).id} : {step: "done", last: ""};
    }

    await writer.close();
    await stateRef.set({...next, done: next.step === "done",
      updatedAt: FieldValue.serverTimestamp()}, {merge: true});
  },
);

// Exported for tests.
exports._internals = {keywordsFrom, trendingScore, hasVideo};
