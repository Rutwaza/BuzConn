/**
 * #hashtags and @mentions.
 *
 * - Posts get `hashtags: ["kigali", "food"]` (lowercase, set by feed.js),
 *   so the app can show all posts with a tag (HashtagPage).
 * - "@username" in a post or a comment notifies that person (type
 *   "mention"), once per post/comment, at most 10 people.
 */
const admin = require("firebase-admin");
const {onDocumentCreated} = require("firebase-functions/v2/firestore");

const REGION = "us-central1";
const db = () => admin.firestore();
const {FieldValue} = require("firebase-admin/firestore");

// Letters (any language), digits and _ ; 2-40 long. Same rule as the app.
const TAG_RE = /(^|[^\p{L}\p{N}_&])#([\p{L}\p{N}_]{2,40})/gu;
const MENTION_RE = /(^|[^\p{L}\p{N}_.@])@([a-z0-9._]{3,20})/giu;

function hashtagsOf(text) {
  const out = new Set();
  for (const m of String(text || "").matchAll(TAG_RE)) {
    out.add(m[2].toLowerCase());
    if (out.size >= 20) break;
  }
  return [...out];
}

function mentionsOf(text) {
  const out = new Set();
  for (const m of String(text || "").matchAll(MENTION_RE)) {
    out.add(m[2].toLowerCase().replace(/\.+$/, ""));
    if (out.size >= 10) break;
  }
  return [...out];
}

async function notifyMentions({text, fromUserId, fromName, fromImage, postId, skip = []}) {
  const names = mentionsOf(text);
  if (!names.length || !fromUserId) return 0;
  const snaps = await Promise.all(names.map((n) => db().collection("usernames").doc(n).get()));
  const uids = [...new Set(snaps.map((s) => s.data()?.uid).filter(Boolean))]
    .filter((u) => u !== fromUserId && !skip.includes(u));
  await Promise.all(uids.map((toUserId) => db().collection("notifications").add({
    toUserId,
    fromUserId,
    fromUserName: fromName || "Someone",
    fromUserImageUrl: fromImage || null,
    type: "mention",
    postId,
    preview: String(text || "").trim().slice(0, 120),
    readAt: null,
    hidden: false,
    createdAt: FieldValue.serverTimestamp(),
  })));
  return uids.length;
}

exports.mentionsInPost = onDocumentCreated(
  {region: REGION, document: "posts/{postId}"},
  async (event) => {
    const post = event.data?.data();
    if (!post || !post.content) return;
    let name = post.businessName;
    let image = post.businessImageUrl;
    if (!post.businessId) {
      const u = (await db().collection("users").doc(post.ownerId).get()).data() || {};
      name = u.name || name;
      image = u.imageUrl || image;
    }
    await notifyMentions({
      text: post.content, fromUserId: post.ownerId, fromName: name, fromImage: image,
      postId: event.params.postId,
    });
  },
);

exports.mentionsInComment = onDocumentCreated(
  {region: REGION, document: "posts/{postId}/comments/{commentId}"},
  async (event) => {
    const c = event.data?.data();
    if (!c || !c.content || c.migrated === true) return;
    // The post owner and the person replied to already get a "comment"
    // notification (social.js): don't send them a second one.
    const post = (await db().collection("posts").doc(event.params.postId).get()).data() || {};
    await notifyMentions({
      text: c.content, fromUserId: c.userId, fromName: c.userName, fromImage: c.userImageUrl,
      postId: event.params.postId, skip: [post.ownerId, c.replyToUserId].filter(Boolean),
    });
  },
);

exports._tagsInternals = {hashtagsOf, mentionsOf};
