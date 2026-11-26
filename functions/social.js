/**
 * Social features that must run on the server (Phase 1 security fixes).
 *
 * Why this file exists:
 * - Phones are not trusted. Before, the app created notifications itself and
 *   rewrote a post's whole `comments` list, so any user could fake
 *   notifications or delete other people's comments.
 * - Now the app only writes small, checkable things (my message, my follow,
 *   my like). Everything that touches other users' data happens here.
 */
const admin = require("firebase-admin");
const {
  onDocumentCreated, onDocumentUpdated, onDocumentDeleted,
} = require("firebase-functions/v2/firestore");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const logger = require("firebase-functions/logger");

const REGION = "us-central1";
const MAX_PREVIEW_LENGTH = 120;

const db = () => admin.firestore();
const FieldValue = admin.firestore.FieldValue;

function clip(text, max = MAX_PREVIEW_LENGTH) {
  const value = String(text || "").trim();
  return value.length > max ? `${value.slice(0, max - 1)}…` : value;
}

/** Drops undefined values: Firestore refuses them. */
function clean(obj) {
  return Object.fromEntries(Object.entries(obj).filter(([, v]) => v !== undefined));
}

async function publicProfile(uid) {
  const snap = await db().collection("users").doc(uid).get();
  const data = snap.data() || {};
  const imageUrl = String(data.imageUrl || "").trim();
  return {
    name: String(data.name || data.displayName || "User"),
    imageUrl: imageUrl || null,
  };
}

/**
 * Creates one notification document. The existing
 * `sendNotificationDocumentPush` function then sends the phone push.
 */
async function notify({toUserId, fromUserId, type, from, extra = {}}) {
  if (!toUserId || !fromUserId || toUserId === fromUserId) return;
  const sender = from || await publicProfile(fromUserId);
  await db().collection("notifications").add(clean({
    ...extra,
    toUserId,
    fromUserId,
    fromUserName: sender.name,
    fromUserImageUrl: sender.imageUrl || null,
    type,
    readAt: null,
    hidden: false,
    createdAt: FieldValue.serverTimestamp(),
  }));
}

// ---------------------------------------------------------------------------
// Follows: the app creates `user_follows/{follower_following}`.
// ---------------------------------------------------------------------------
exports.notifyOnFollow = onDocumentCreated(
  {region: REGION, document: "user_follows/{followId}"},
  async (event) => {
    const follow = event.data?.data();
    if (!follow) return;
    await notify({
      toUserId: String(follow.followingId || ""),
      fromUserId: String(follow.followerId || ""),
      type: "follow",
    });
  },
);

// ---------------------------------------------------------------------------
// Chat messages: one notification per other participant.
// ---------------------------------------------------------------------------
exports.notifyOnChatMessage = onDocumentCreated(
  {region: REGION, document: "chats/{chatId}/messages/{messageId}"},
  async (event) => {
    const message = event.data?.data();
    if (!message) return;
    if (message.mediaType === "call") return; // call results have their own flow

    const senderId = String(message.senderId || "");
    const chatSnap = await db().collection("chats").doc(event.params.chatId).get();
    const chat = chatSnap.data() || {};
    const participants = (Array.isArray(chat.participants) ? chat.participants : [])
      .map(String);
    if (!senderId || !participants.includes(senderId)) return;

    const isRequest = chat.requestStatus === "pending" && chat.requesterId === senderId;
    const isGhost = message.isGhost === true;
    if (isGhost && !isRequest) return; // ghost chats stay silent

    let preview;
    if (message.mediaUrl) preview = "[media]";
    else if (isGhost) preview = "Sent you a message";
    else preview = clip(message.text);
    if (chat.chatType === "group") {
      // "Team Duhuze · Alice: hello"
      preview = `${clip(chat.groupName || "Group")} · ${String(message.senderName || "Someone")}: ${preview}`;
    }

    const from = {
      name: String(message.senderName || "User"),
      imageUrl: message.senderAvatar || null,
    };
    for (const uid of participants) {
      if (uid === senderId) continue;
      await notify({
        toUserId: uid,
        fromUserId: senderId,
        type: isRequest ? "message_request" : "message",
        from,
        extra: {chatId: event.params.chatId, preview},
      });
    }
  },
);

// ---------------------------------------------------------------------------
// Phase 2: likes and comments are their own documents.
//   posts/{postId}/likes/{uid}
//   posts/{postId}/comments/{commentId}   (likes on a comment: `likes` list)
// These triggers keep post.likeCount / post.commentCount right and send the
// notifications. The app can't change the counters (Firestore rules).
// ---------------------------------------------------------------------------
async function bumpPost(postId, field, delta) {
  try {
    await db().collection("posts").doc(postId).update({
      [field]: FieldValue.increment(delta),
    });
  } catch (error) {
    // The post may have been deleted; nothing to count then.
    logger.info("Counter not updated", {postId, field, error: String(error)});
  }
}

async function postOwnerId(postId) {
  const snap = await db().collection("posts").doc(postId).get();
  return String(snap.data()?.ownerId || "");
}

exports.onPostLiked = onDocumentCreated(
  {region: REGION, document: "posts/{postId}/likes/{uid}"},
  async (event) => {
    const {postId, uid} = event.params;
    if (event.data?.data()?.migrated === true) return; // counted by migration
    await bumpPost(postId, "likeCount", 1);
    await notify({
      toUserId: await postOwnerId(postId),
      fromUserId: uid,
      type: "like",
      extra: {postId},
    });
  },
);

exports.onPostUnliked = onDocumentDeleted(
  {region: REGION, document: "posts/{postId}/likes/{uid}"},
  async (event) => bumpPost(event.params.postId, "likeCount", -1),
);

exports.onCommentCreated = onDocumentCreated(
  {region: REGION, document: "posts/{postId}/comments/{commentId}"},
  async (event) => {
    const comment = event.data?.data();
    if (!comment || comment.migrated === true) return; // counted by migration
    const {postId} = event.params;
    await bumpPost(postId, "commentCount", 1);

    const from = {
      name: String(comment.userName || "User"),
      imageUrl: comment.userImageUrl || null,
    };
    const ownerId = await postOwnerId(postId);
    const content = String(comment.content || "");
    await notify({
      toUserId: ownerId, fromUserId: comment.userId, type: "comment", from,
      extra: {postId, preview: clip(content)},
    });
    const replyTo = String(comment.replyToUserId || "");
    if (replyTo && replyTo !== ownerId) {
      await notify({
        toUserId: replyTo, fromUserId: comment.userId, type: "comment", from,
        extra: {postId, preview: clip(`@${comment.replyToUserName || ""} ${content}`)},
      });
    }
  },
);

exports.onCommentDeleted = onDocumentDeleted(
  {region: REGION, document: "posts/{postId}/comments/{commentId}"},
  async (event) => bumpPost(event.params.postId, "commentCount", -1),
);

exports.onCommentLiked = onDocumentUpdated(
  {region: REGION, document: "posts/{postId}/comments/{commentId}"},
  async (event) => {
    const before = new Set(event.data?.before?.data()?.likes || []);
    const after = event.data?.after?.data() || {};
    const added = (after.likes || []).filter((uid) => !before.has(uid)).slice(0, 10);
    for (const uid of added) {
      await notify({
        toUserId: String(after.userId || ""),
        fromUserId: String(uid),
        type: "like",
        extra: {postId: event.params.postId, preview: "liked your comment"},
      });
    }
  },
);

// ---------------------------------------------------------------------------
// One-time maintenance, runs by itself every 10 minutes until finished, then
// does nothing. Delete this function after the "_maintenance/phase2" doc says
// done: true (Firebase console -> Firestore).
//  1. Gives the owner account the admin claim (no laptop script needed).
//  2. Moves push tokens from users/{uid} to users_private/{uid}.
//  3. Moves old likes/comments lists into the new documents.
// ---------------------------------------------------------------------------
const OWNER_EMAILS = ["nelsonjembe99@gmail.com"];

exports.phase2Maintenance = onSchedule(
  {region: REGION, schedule: "every 10 minutes", timeoutSeconds: 540, memory: "512MiB"},
  async () => {
    const stateRef = db().collection("_maintenance").doc("phase2");
    const state = (await stateRef.get()).data() || {};
    if (state.done === true) return;

    // 1. Admin claim
    for (const email of OWNER_EMAILS) {
      try {
        const user = await admin.auth().getUserByEmail(email);
        if (user.emailVerified && user.customClaims?.admin !== true) {
          await admin.auth().setCustomUserClaims(user.uid,
            {...(user.customClaims || {}), admin: true});
          logger.info("Admin claim set", {email});
        }
      } catch (error) {
        logger.warn("Admin claim not set", {email, error: String(error)});
      }
    }

    // 2. Push tokens (batches of 200 users)
    const withTokens = await db().collection("users")
      .where("fcmTokens", "!=", null).limit(200).get();
    for (const doc of withTokens.docs) {
      const tokens = (doc.data().fcmTokens || []).filter(Boolean);
      const batch = db().batch();
      if (tokens.length) {
        batch.set(db().collection("users_private").doc(doc.id),
          {fcmTokens: FieldValue.arrayUnion(...tokens)}, {merge: true});
      }
      batch.update(doc.ref, {fcmTokens: FieldValue.delete()});
      await batch.commit();
    }

    // 3. Old likes/comments lists -> documents (50 posts per run, walking
    //    the posts in id order; lastPostId remembers where we stopped).
    const page = await db().collection("posts")
      .orderBy(admin.firestore.FieldPath.documentId())
      .startAfter(String(state.lastPostId || ""))
      .limit(50).get();
    const candidates = page.docs;

    for (const postDoc of candidates) {
      const post = postDoc.data() || {};
      state.lastPostId = postDoc.id;
      const hasLegacy = Array.isArray(post.likes) || Array.isArray(post.comments);
      if (post.engagementMigrated === true || !hasLegacy) continue;

      const likes = [...new Set((post.likes || []).filter(Boolean).map(String))];
      const comments = (post.comments || []).filter((c) => c && c.userId);
      // Someone may already have liked again with the new app: don't count twice.
      const existing = new Set((await postDoc.ref.collection("likes").select().get())
        .docs.map((d) => d.id));
      const newLikes = likes.filter((uid) => !existing.has(uid));

      const writer = db().bulkWriter();
      const when = post.updatedAt || post.createdAt || null;
      for (const uid of newLikes) {
        const data = {userId: uid, createdAt: when, migrated: true};
        writer.set(postDoc.ref.collection("likes").doc(uid), data);
        writer.set(db().collection("users").doc(uid)
          .collection("liked_posts").doc(postDoc.id), data);
      }
      for (const c of comments) {
        const id = String(c.id || "") || db().collection("posts").doc().id;
        writer.set(postDoc.ref.collection("comments").doc(id), {
          userId: String(c.userId),
          userName: String(c.userName || "User"),
          content: String(c.content || ""),
          likes: Array.isArray(c.likes) ? c.likes : [],
          createdAt: c.createdAt || post.createdAt || null,
          replyToUserId: c.replyToUserId || null,
          replyToUserName: c.replyToUserName || null,
          replyToCommentId: c.replyToCommentId || null,
          migrated: true,
        });
      }
      await writer.close();
      // increment (not set): new likes/comments made since the update are
      // already counted by the triggers.
      await postDoc.ref.update({
        likeCount: FieldValue.increment(newLikes.length),
        commentCount: FieldValue.increment(comments.length),
        likes: FieldValue.delete(),
        comments: FieldValue.delete(),
        engagementMigrated: true,
      });
    }

    const finished = candidates.length === 0 && withTokens.empty;
    await stateRef.set({
      lastPostId: state.lastPostId || "",
      done: finished,
      updatedAt: FieldValue.serverTimestamp(),
    }, {merge: true});
  },
);
