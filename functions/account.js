/**
 * Account deletion (required by Google Play).
 *
 * `deleteAccount` (callable) removes, for the signed-in user:
 *   - profile: users/{uid} (+ liked_posts, favorites), users_private/{uid},
 *     usernames, timelines/{uid}
 *   - content: posts (+ their likes/comments), pages/businesses (+ products),
 *     statuses (+ views), the user's comments and likes on other posts
 *   - follows (both directions), page follows, notifications to/from them
 *   - public photos/videos in R2 (public/<category>/<uid>/...)
 *   - the Firebase Auth account itself
 * Kept on purpose (written in the privacy policy):
 *   - chats: messages stay with the other person, like on WhatsApp
 *   - shop orders: the shop keeps its sales record
 *   - ghost archive copies: kept 90 more days for safety reports, then
 *     deleted by `purgeDeletedAccountData`
 *
 * For safety the user must have signed in during the last 15 minutes.
 */
const admin = require("firebase-admin");
const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const {defineSecret, defineString} = require("firebase-functions/params");
const logger = require("firebase-functions/logger");
const {S3Client, ListObjectsV2Command, DeleteObjectsCommand} = require("@aws-sdk/client-s3");

const REGION = "us-central1";
const RECENT_LOGIN_SECONDS = 15 * 60;
const GHOST_KEEP_DAYS = 90;
const R2_ACCOUNT_ID = defineString("R2_ACCOUNT_ID");
const R2_PUBLIC_BUCKET_NAME = defineString("R2_PUBLIC_BUCKET_NAME");
const R2_ACCESS_KEY_ID = defineSecret("R2_ACCESS_KEY_ID");
const R2_SECRET_ACCESS_KEY = defineSecret("R2_SECRET_ACCESS_KEY");

const db = () => admin.firestore();

/** Deletes every doc of a query (and its subcollections), 200 at a time. */
async function deleteQuery(query) {
  let count = 0;
  for (;;) {
    const snap = await query.limit(200).get();
    if (snap.empty) return count;
    for (const doc of snap.docs) {
      await db().recursiveDelete(doc.ref);
      count++;
    }
  }
}

async function deleteR2Media(uid) {
  const client = new S3Client({
    region: "auto",
    endpoint: `https://${R2_ACCOUNT_ID.value()}.r2.cloudflarestorage.com`,
    credentials: {
      accessKeyId: R2_ACCESS_KEY_ID.value(),
      secretAccessKey: R2_SECRET_ACCESS_KEY.value(),
    },
  });
  const bucket = R2_PUBLIC_BUCKET_NAME.value();
  let removed = 0;
  try {
    for (const category of ["profile-images", "post-images", "post-videos"]) {
      let token;
      do {
        const list = await client.send(new ListObjectsV2Command({
          Bucket: bucket, Prefix: `public/${category}/${uid}/`, ContinuationToken: token,
        }));
        const keys = (list.Contents || []).map((o) => ({Key: o.Key}));
        if (keys.length) {
          await client.send(new DeleteObjectsCommand({Bucket: bucket, Delete: {Objects: keys}}));
          removed += keys.length;
        }
        token = list.IsTruncated ? list.NextContinuationToken : undefined;
      } while (token);
    }
  } finally {
    client.destroy();
  }
  return removed;
}

exports.deleteAccount = onCall(
  {region: REGION, timeoutSeconds: 540, memory: "512MiB", secrets: [R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY]},
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");
    const authTime = Number(request.auth.token.auth_time || 0);
    if (Date.now() / 1000 - authTime > RECENT_LOGIN_SECONDS) {
      throw new HttpsError("failed-precondition", "recent-login-required");
    }

    const d = db();
    const counts = {};
    const businesses = await d.collection("businesses").where("ownerId", "==", uid).get();
    const businessIds = businesses.docs.map((b) => b.id);

    counts.posts = await deleteQuery(d.collection("posts").where("ownerId", "==", uid));
    counts.comments = await deleteQuery(d.collectionGroup("comments").where("userId", "==", uid));
    counts.likes = await deleteQuery(d.collectionGroup("likes").where("userId", "==", uid));
    counts.statuses = await deleteQuery(d.collection("statuses").where("ownerId", "==", uid));
    counts.follows = await deleteQuery(d.collection("user_follows").where("followerId", "==", uid)) +
      await deleteQuery(d.collection("user_follows").where("followingId", "==", uid));
    counts.pageFollows = await deleteQuery(d.collection("page_follows").where("followerId", "==", uid));
    for (const pageId of businessIds) {
      counts.pageFollows += await deleteQuery(d.collection("page_follows").where("pageId", "==", pageId));
    }
    counts.businesses = await deleteQuery(d.collection("businesses").where("ownerId", "==", uid));
    counts.notifications = await deleteQuery(d.collection("notifications").where("toUserId", "==", uid)) +
      await deleteQuery(d.collection("notifications").where("fromUserId", "==", uid));
    await deleteQuery(d.collection("usernames").where("uid", "==", uid));

    // Ghost copies: keep 90 days for safety reports, then purge.
    const deleteAfter = admin.firestore.Timestamp.fromMillis(Date.now() + GHOST_KEEP_DAYS * 86400000);
    const ghosts = await d.collection("ghost_archive").where("senderId", "==", uid).get();
    for (let i = 0; i < ghosts.docs.length; i += 400) {
      const batch = d.batch();
      ghosts.docs.slice(i, i + 400).forEach((g) => batch.update(g.ref, {deleteAfter}));
      await batch.commit();
    }

    await d.recursiveDelete(d.collection("timelines").doc(uid));
    await d.recursiveDelete(d.collection("users_private").doc(uid));
    await d.recursiveDelete(d.collection("users").doc(uid));

    try {
      counts.mediaFiles = await deleteR2Media(uid);
    } catch (e) {
      logger.error("R2 media cleanup failed", {uid, error: e.message});
      counts.mediaFiles = "failed";
    }

    await d.collection("admin_events").add({
      type: "account_deleted",
      uid, // no name or email kept
      counts,
      at: admin.firestore.FieldValue.serverTimestamp(),
    });
    await admin.auth().deleteUser(uid);
    return {ok: true};
  },
);

exports.purgeDeletedAccountData = onSchedule(
  {region: REGION, schedule: "every 24 hours", timeoutSeconds: 300},
  async () => {
    const n = await deleteQuery(db().collection("ghost_archive")
      .where("deleteAfter", "<=", admin.firestore.Timestamp.now()));
    if (n) logger.info(`Purged ${n} ghost archive copies of deleted accounts`);
  },
);
