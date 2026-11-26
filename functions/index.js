const admin = require("firebase-admin");
const crypto = require("crypto");
const {S3Client, PutObjectCommand, GetObjectCommand} = require("@aws-sdk/client-s3");
const {getSignedUrl} = require("@aws-sdk/s3-request-presigner");
const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {defineSecret, defineString} = require("firebase-functions/params");
const logger = require("firebase-functions/logger");
const {setGlobalOptions} = require("firebase-functions/v2");

// Small, cheap instances. Without this every function asks for 1 full CPU and
// up to 100 instances, and together they hit Google's per-region CPU quota
// ("Quota exceeded for total allowable CPU"). "gcf_gen1" gives each instance
// a fraction of a CPU (like 1st-gen functions). Raise these when traffic grows.
setGlobalOptions({maxInstances: 10, cpu: "gcf_gen1", memory: "256MiB"});

admin.initializeApp();
const db = admin.firestore();

// Server-side social features (notifications, comments). See social.js.
Object.assign(exports, require("./social"));
// Feed, reels, search and unread counters (Phase 3). See feed.js.
// eslint-disable-next-line no-unused-vars
const {_internals: _feedInternals, ...feedFunctions} = require("./feed");
Object.assign(exports, feedFunctions);
// Ghost messages: encrypted server-side archive + admin-only decrypt. See ghost.js.
// eslint-disable-next-line no-unused-vars
const {_ghostInternals, ...ghostFunctions} = require("./ghost");
Object.assign(exports, ghostFunctions);
// Shop: catalogs, orders, MoMo payments. See shop.js and payments/.
const {_shopInternals, ...shopFunctions} = require("./shop");
Object.assign(exports, shopFunctions);
const {_groupInternals, ...groupFunctions} = require("./groups");
const {_verificationInternals, ...verificationFunctions} = require("./verification");
Object.assign(exports, verificationFunctions);
Object.assign(exports, groupFunctions);
// Duhuze earnings: extra pages and boosted posts (IremboPay). See billing.js.
// eslint-disable-next-line no-unused-vars
const {_billingInternals, ...billingFunctions} = require("./billing");
Object.assign(exports, billingFunctions);
// Creating pages (paid slots) and the page team. See pages.js.
// eslint-disable-next-line no-unused-vars
const {_pagesInternals, ...pagesFunctions} = require("./pages");
Object.assign(exports, pagesFunctions);
// #hashtags and @mentions. See tags.js.
// eslint-disable-next-line no-unused-vars
const {_tagsInternals, ...tagsFunctions} = require("./tags");
Object.assign(exports, tagsFunctions);
// Status (24h stories): view counter + hourly cleanup. See status.js.
Object.assign(exports, require("./status"));
// Account deletion (Google Play requirement). See account.js.
Object.assign(exports, require("./account"));
// Moderation: admin alert for each report. See moderation.js.
Object.assign(exports, require("./moderation"));
// Admin panel actions (reports, suspend, moderators, stats). See admin.js.
// eslint-disable-next-line no-unused-vars
const {_adminInternals, ...adminFunctions} = require("./admin");
Object.assign(exports, adminFunctions);

const R2_ACCOUNT_ID = defineString("R2_ACCOUNT_ID");
const R2_PUBLIC_BUCKET_NAME = defineString("R2_PUBLIC_BUCKET_NAME");
const R2_PRIVATE_BUCKET_NAME = defineString("R2_PRIVATE_BUCKET_NAME");
const R2_PUBLIC_BASE_URL = defineString("R2_PUBLIC_BASE_URL");
const R2_ACCESS_KEY_ID = defineSecret("R2_ACCESS_KEY_ID");
const R2_SECRET_ACCESS_KEY = defineSecret("R2_SECRET_ACCESS_KEY");

const R2_ALLOWED_PUBLIC_CATEGORIES = new Set([
  "profile-images",
  "post-images",
  "post-videos",
]);
const R2_MAX_UPLOAD_BYTES = 250 * 1024 * 1024;

function r2Encode(value) {
  return encodeURIComponent(value).replace(/[!'()*]/g, (char) =>
    `%${char.charCodeAt(0).toString(16).toUpperCase()}`,
  );
}

async function createR2PresignedUrl({method, bucket, key, contentType = "", expiresIn = 600}) {
  const client = new S3Client({
    region: "auto",
    endpoint: `https://${R2_ACCOUNT_ID.value()}.r2.cloudflarestorage.com`,
    credentials: {
      accessKeyId: R2_ACCESS_KEY_ID.value(),
      secretAccessKey: R2_SECRET_ACCESS_KEY.value(),
    },
  });
  try {
    const command = method === "PUT" ?
      new PutObjectCommand({Bucket: bucket, Key: key, ContentType: contentType}) :
      new GetObjectCommand({Bucket: bucket, Key: key});
    const url = await getSignedUrl(client, command, {expiresIn});
    return method === "PUT" ? {url, headers: {"Content-Type": contentType}} : {url};
  } finally {
    client.destroy();
  }
}

function normalizeR2ContentType(value) {
  const contentType = String(value || "application/octet-stream").trim().toLowerCase();
  const allowed = /^(image\/(jpeg|png|webp)|video\/(mp4|quicktime|webm)|audio\/(mp4|mpeg|wav|webm)|application\/(pdf|msword|vnd\.[a-z0-9.+-]+|zip|x-zip-compressed|octet-stream)|text\/(plain|csv))$/;
  if (!allowed.test(contentType)) {
    throw new HttpsError("invalid-argument", "This file type is not supported.");
  }
  return contentType;
}

const SUPER_ADMIN_EMAILS = new Set([
  "nelsonjembe99@gmail.com",
]);

function normalizeUsername(username) {
  return String(username || "").trim().toLowerCase();
}

function isValidUsername(username) {
  return /^[a-z0-9._]{3,20}$/.test(normalizeUsername(username));
}

exports.sendNotificationDocumentPush = onDocumentCreated(
  "notifications/{notificationId}",
  async (event) => {
    const notification = event.data?.data();
    if (!notification) return;

    const toUserId = notification.toUserId;
    if (!toUserId) return;

    // Device tokens now live in users_private/{uid} (only the owner can read
    // it). Old accounts may still have them on users/{uid}; use both.
    const [privateSnap, userSnap] = await Promise.all([
      db.collection("users_private").doc(toUserId).get(),
      db.collection("users").doc(toUserId).get(),
    ]);
    const privateTokens = privateSnap.data()?.fcmTokens;
    const legacyTokens = userSnap.data()?.fcmTokens;
    const tokens = [...new Set([
      ...(Array.isArray(privateTokens) ? privateTokens : []),
      ...(Array.isArray(legacyTokens) ? legacyTokens : []),
    ].filter(Boolean))];

    if (!tokens.length) {
      logger.info("No FCM tokens for user", {toUserId});
      return;
    }

    const type = String(notification.type || "");
    const fromName = String(notification.fromUserName || "Someone");
    const preview = String(notification.preview || "");

    const message = {
      tokens,
      notification: {
        title: buildTitle(type, fromName),
        body: buildBody(type, fromName, preview),
      },
      data: {
        type,
        chatId: String(notification.chatId || ""),
        postId: String(notification.postId || ""),
        userId: String(notification.fromUserId || ""),
        fromUserId: String(notification.fromUserId || ""),
        fromUserName: fromName,
        preview,
      },
      android: {
        priority: "high",
        notification: {
          channelId: type === "call" ? "spotlight_calls" :
            (type === "message" || type === "message_request" ?
              "spotlight_chat" : "spotlight_activity"),
        },
      },
      apns: {
        payload: {
          aps: {
            sound: "default",
          },
        },
      },
    };

    const response = await admin.messaging().sendEachForMulticast(message);

    const invalidTokens = [];
    response.responses.forEach((result, index) => {
      if (result.success) return;
      const code = result.error?.code || "";
      if (
        code === "messaging/registration-token-not-registered" ||
        code === "messaging/invalid-registration-token"
      ) {
        invalidTokens.push(tokens[index]);
      }
      logger.warn("Failed push send", {code, token: tokens[index]});
    });

    if (invalidTokens.length) {
      const removal = {
        fcmTokens: admin.firestore.FieldValue.arrayRemove(...invalidTokens),
      };
      await Promise.all([
        db.collection("users_private").doc(toUserId).set(removal, {merge: true}),
        db.collection("users").doc(toUserId).set(removal, {merge: true}),
      ]);
    }
  },
);

exports.sendIncomingCallPush = onDocumentCreated(
  "chats/{chatId}/calls/active",
  async (event) => {
    const call = event.data?.data();
    if (!call?.callerId) return;
    const chatSnap = await db.collection("chats").doc(event.params.chatId).get();
    const participants = chatSnap.data()?.participants || [];
    const recipientIds = participants.filter((id) => id !== call.callerId);
    const callerSnap = await db.collection("users").doc(call.callerId).get();
    const callerName = String(callerSnap.data()?.name || "Someone");
    const kind = call.callType === "audio" ? "voice" : "video";

    for (const recipientId of recipientIds) {
      await db.collection("notifications").add({
        toUserId: recipientId,
        fromUserId: call.callerId,
        fromUserName: callerName,
        type: "call",
        chatId: event.params.chatId,
        callType: String(call.callType || "video"),
        preview: `${callerName} is calling you by ${kind}`,
        readAt: null,
        hidden: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  },
);

/**
 * Auto-discover buses from RTDB device nodes.
 * Triggered once when /devices/{busId} is first created.
 */
exports.createR2UploadUrl = onCall({
  region: "us-central1",
  secrets: [R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY],
}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in before uploading media.");
  }

  const uid = request.auth.uid;
  const category = String(request.data?.category || "");
  const contentType = normalizeR2ContentType(request.data?.contentType);
  const sizeBytes = Number(request.data?.sizeBytes);
  const fileName = String(request.data?.fileName || "file");
  if (!Number.isSafeInteger(sizeBytes) || sizeBytes < 1 || sizeBytes > R2_MAX_UPLOAD_BYTES) {
    throw new HttpsError("invalid-argument", "File is too large (maximum 250 MB).");
  }

  const extension = fileName.split(".").pop().toLowerCase().replace(/[^a-z0-9]/g, "").slice(0, 10);
  const suffix = extension ? `.${extension}` : "";
  const objectId = crypto.randomUUID();
  let objectKey;
  let privateChat = false;

  if (category === "chat-media") {
    const chatId = String(request.data?.chatId || "").trim();
    if (!chatId || chatId.includes("/")) {
      throw new HttpsError("invalid-argument", "A valid chat is required for private media.");
    }
    const chatSnapshot = await db.collection("chats").doc(chatId).get();
    if (!chatSnapshot.exists) {
      throw new HttpsError("not-found", "Chat not found.");
    }
    const chat = chatSnapshot.data() || {};
    const participants = Array.isArray(chat.participants) ? chat.participants : [];
    const requestStatus = String(chat.requestStatus || "none");
    const canSend = requestStatus !== "rejected" &&
      (requestStatus !== "pending" || chat.requesterId === uid);
    if (!participants.includes(uid) || !canSend) {
      throw new HttpsError("permission-denied", "You cannot upload media to this chat.");
    }
    objectKey = `private/chats/${chatId}/${uid}/${objectId}${suffix}`;
    privateChat = true;
  } else {
    if (!R2_ALLOWED_PUBLIC_CATEGORIES.has(category)) {
      throw new HttpsError("invalid-argument", "Unknown media category.");
    }
    if (category === "post-videos" && !contentType.startsWith("video/")) {
      throw new HttpsError("invalid-argument", "Post videos must be video files.");
    }
    if (category !== "post-videos" && !contentType.startsWith("image/")) {
      throw new HttpsError("invalid-argument", "This upload category only accepts images.");
    }
    objectKey = `public/${category}/${uid}/${objectId}${suffix}`;
  }

  const storageBucket = privateChat ?
    R2_PRIVATE_BUCKET_NAME.value() : R2_PUBLIC_BUCKET_NAME.value();
  const signed = await createR2PresignedUrl({
    method: "PUT",
    bucket: storageBucket,
    key: objectKey,
    contentType,
    expiresIn: 600,
  });
  const result = {
    uploadUrl: signed.url,
    headers: signed.headers,
    objectKey,
    mediaRef: privateChat ? `r2://${objectKey}` : null,
  };
  if (!privateChat) {
    const publicBaseUrl = R2_PUBLIC_BASE_URL.value().replace(/\/+$/, "");
    result.publicUrl = `${publicBaseUrl}/${objectKey.split("/").map(r2Encode).join("/")}`;
  }
  return result;
});

exports.createR2DownloadUrl = onCall({
  region: "us-central1",
  secrets: [R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY],
}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in to view this attachment.");
  }
  const uid = request.auth.uid;
  const chatId = String(request.data?.chatId || "").trim();
  const objectKey = String(request.data?.objectKey || "");
  if (!chatId || chatId.includes("/") ||
      !objectKey.startsWith(`private/chats/${chatId}/`)) {
    throw new HttpsError("invalid-argument", "Invalid private media reference.");
  }
  const chatSnapshot = await db.collection("chats").doc(chatId).get();
  const participants = chatSnapshot.exists && Array.isArray(chatSnapshot.data()?.participants) ?
    chatSnapshot.data().participants : [];
  if (!participants.includes(uid)) {
    throw new HttpsError("permission-denied", "You cannot view this chat attachment.");
  }
  return {
    url: (await createR2PresignedUrl({
      method: "GET",
      bucket: R2_PRIVATE_BUCKET_NAME.value(),
      key: objectKey,
      expiresIn: 900,
    })).url,
    expiresIn: 900,
  };
});

exports.claimUsername = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const uid = request.auth.uid;
  await assertUserIsActive(uid);
  const username = normalizeUsername(request.data?.username || "");
  if (!isValidUsername(username)) {
    throw new HttpsError(
      "invalid-argument",
      "Username must be 3-20 chars: lowercase letters, numbers, dot, underscore.",
    );
  }

  const now = admin.firestore.Timestamp.now();
  const usernameRef = db.collection("usernames").doc(username);
  const userRef = db.collection("users").doc(uid);

  await db.runTransaction(async (tx) => {
    const [usernameSnap, userSnap] = await Promise.all([
      tx.get(usernameRef),
      tx.get(userRef),
    ]);

    const current = normalizeUsername(userSnap.data()?.username || "");
    if (current && current !== username) {
      throw new HttpsError(
        "failed-precondition",
        "Username already set and cannot be changed.",
      );
    }

    if (usernameSnap.exists) {
      const ownerUid = String(usernameSnap.data()?.uid || "");
      if (ownerUid !== uid) {
        throw new HttpsError("already-exists", "Username is already taken.");
      }
    } else {
      tx.set(usernameRef, {
        uid,
        username,
        createdAt: now,
      });
    }

    tx.set(userRef, {
      username,
      usernameLower: username,
      updatedAt: now,
      createdAt: userSnap.exists ? userSnap.data()?.createdAt || now : now,
    }, {merge: true});
  });

  return {ok: true, username};
});

async function assertUserIsActive(uid) {
  const userSnap = await db.collection("users").doc(uid).get();
  if (!userSnap.exists) {
    throw new HttpsError("permission-denied", "User not found.");
  }
  const user = userSnap.data() || {};
  if (user.isActive === false) {
    throw new HttpsError("failed-precondition", "Your account is inactive.");
  }
}

// Admin = the `admin: true` custom claim (set with functions/scripts/set-admin.js).
// The email list is a temporary fallback until the claim is set; it only
// counts for a verified email. Remove SUPER_ADMIN_EMAILS once the claim works.
function isSuperAdminAuth(request) {
  const token = request.auth?.token || {};
  if (token.admin === true) return true;
  const email = String(token.email || "").toLowerCase();
  return token.email_verified === true && SUPER_ADMIN_EMAILS.has(email);
}

function assertSuperAdmin(request) {
  if (!isSuperAdminAuth(request)) {
    throw new HttpsError("permission-denied", "Super admin only.");
  }
}

exports.getSystemCounts = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  assertSuperAdmin(request);

  const [usersSnap, pagesSnap, activeUsersSnap, activePagesSnap] =
    await Promise.all([
      db.collection("users").count().get(),
      db.collection("businesses").count().get(),
      db.collection("users").where("isActive", "!=", false).count().get(),
      db.collection("businesses").where("isActive", "==", true).count().get(),
    ]);

  return {
    ok: true,
    totals: {
      users: usersSnap.data().count || 0,
      pages: pagesSnap.data().count || 0,
    },
    active: {
      users: activeUsersSnap.data().count || 0,
      pages: activePagesSnap.data().count || 0,
    },
  };
});

exports.setEntityActive = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  assertSuperAdmin(request);

  const entityType = String(request.data?.entityType || "").trim();
  const entityId = String(request.data?.entityId || "").trim();
  const active = request.data?.active === true;
  if (!entityType || !entityId || !["user", "page"].includes(entityType)) {
    throw new HttpsError("invalid-argument", "Invalid entityType/entityId.");
  }

  const now = admin.firestore.Timestamp.now();
  if (entityType === "user") {
    await db.collection("users").doc(entityId).set({
      isActive: active,
      updatedAt: now,
    }, {merge: true});
  } else {
    await db.collection("businesses").doc(entityId).set({
      isActive: active,
      updatedAt: now,
    }, {merge: true});
  }

  return {ok: true, entityType, entityId, active};
});

exports.exportEntityData = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  assertSuperAdmin(request);

  const entityType = String(request.data?.entityType || "").trim();
  const entityId = String(request.data?.entityId || "").trim();
  const format = String(request.data?.format || "json").trim();
  if (!entityType || !entityId || !["user", "page"].includes(entityType)) {
    throw new HttpsError("invalid-argument", "Invalid entityType/entityId.");
  }

  const collection = entityType === "user" ? "users" : "businesses";
  const docSnap = await db.collection(collection).doc(entityId).get();
  if (!docSnap.exists) {
    throw new HttpsError("not-found", "Entity not found.");
  }
  const docData = docSnap.data() || {};

  if (format === "csv") {
    const rows = Object.entries(docData).map(([k, v]) => `${k},"${String(v).replaceAll('"', '""')}"`);
    return {
      ok: true,
      format: "csv",
      filename: `${entityType}_${entityId}.csv`,
      content: `key,value\n${rows.join("\n")}`,
    };
  }

  return {
    ok: true,
    format: "json",
    filename: `${entityType}_${entityId}.json`,
    content: JSON.stringify({
      entityType,
      entityId,
      data: docData,
      exportedAt: new Date().toISOString(),
    }, null, 2),
  };
});

exports.exportChatBetweenUsers = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  assertSuperAdmin(request);

  const userA = String(request.data?.userA || "").trim();
  const userB = String(request.data?.userB || "").trim();
  if (!userA || !userB || userA === userB) {
    throw new HttpsError("invalid-argument", "Provide two distinct user ids.");
  }

  const chatsSnap = await db.collection("chats")
    .where("participants", "array-contains", userA)
    .get();
  let targetChat = null;
  for (const doc of chatsSnap.docs) {
    const p = doc.data().participants || [];
    if (Array.isArray(p) && p.includes(userA) && p.includes(userB)) {
      targetChat = doc;
      break;
    }
  }
  if (!targetChat) {
    throw new HttpsError("not-found", "No chat found for this pair.");
  }

  const msgsSnap = await targetChat.ref.collection("messages")
    .orderBy("timestamp", "asc")
    .limit(2000)
    .get();
  const messages = msgsSnap.docs.map((d) => ({id: d.id, ...d.data()}));
  return {
    ok: true,
    chatId: targetChat.id,
    count: messages.length,
    filename: `chat_${targetChat.id}.json`,
    content: JSON.stringify({
      chatId: targetChat.id,
      participants: targetChat.data().participants || [],
      messages,
      exportedAt: new Date().toISOString(),
    }, null, 2),
  };
});

function buildTitle(type, fromName) {
  switch (type) {
    case "message":
      return fromName;
    case "message_request":
      return "Message request";
    case "call":
      return "Incoming call";
    case "follow":
      return "New follower";
    case "comment":
      return "New comment";
    case "like":
      return "New like";
    case "order":
      return "Duhuze Shop";
    case "report":
      return "Duhuze report";
    default:
      return "Duhuze";
  }
}

function buildBody(type, fromName, preview) {
  switch (type) {
    case "message":
      return preview || `${fromName} sent you a message`;
    case "message_request":
      return `${fromName} wants to message you`;
    case "call":
      return preview || `${fromName} is calling you`;
    case "follow":
      return `${fromName} followed you`;
    case "comment":
      return preview || `${fromName} commented on your post`;
    case "like":
      return preview || `${fromName} liked your post`;
    default:
      return preview || "You have a new Duhuze update.";
  }
}
