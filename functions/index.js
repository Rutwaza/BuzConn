const admin = require("firebase-admin");
const crypto = require("crypto");
const {S3Client, PutObjectCommand, GetObjectCommand} = require("@aws-sdk/client-s3");
const {getSignedUrl} = require("@aws-sdk/s3-request-presigner");
const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const {onCall, onRequest, HttpsError} = require("firebase-functions/v2/https");
const functionsV1 = require("firebase-functions/v1");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const {onValueCreated} = require("firebase-functions/v2/database");
const {defineSecret, defineString} = require("firebase-functions/params");
const logger = require("firebase-functions/logger");

admin.initializeApp();
const db = admin.firestore();

// Server-side social features (notifications, comments). See social.js.
Object.assign(exports, require("./social"));

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

const BOOKING_STATUS = {
  BOOKED: "booked",
  PAID: "paid",
  EXPIRED: "expired",
  CANCELLED: "cancelled",
};

const CORRIDOR_STOPS = [
  "remera",
  "rwamagana",
  "kayonza",
  "kibungo",
  "nyakarambi",
];

const STOP_ALIASES = {
  remera: "remera",
  rwamagana: "rwamagana",
  kayonza: "kayonza",
  kibungo: "kibungo",
  nyakarambi: "nyakarambi",
  kirehe: "nyakarambi",
};

const SEAT_SEGMENT_UNLOCK_MS = 10 * 60 * 1000;

const SUPER_ADMIN_EMAILS = new Set([
  "nelsonjembe99@gmail.com",
]);

const SPOTLIGHT_REVENUE_SHARE_PERCENT = 5;
const SPOTLIGHT_BANK_ACCOUNT = {
  accountName: "SpotLight Company",
  bankName: "Bank of Kigali",
  accountNumber: "SPOTLIGHT-001",
};

function hashPassword(raw) {
  const salt = crypto.randomBytes(16).toString("hex");
  const derived = crypto.scryptSync(String(raw), salt, 64).toString("hex");
  return `s2$${salt}$${derived}`;
}

function legacyHashPassword(raw) {
  return crypto.createHash("sha256").update(String(raw)).digest("hex");
}

function verifyPassword(raw, storedHash) {
  const value = String(storedHash || "");
  if (!value) return false;

  if (value.startsWith("s2$")) {
    const parts = value.split("$");
    if (parts.length !== 3) return false;
    const salt = parts[1];
    const expected = parts[2];
    const actual = crypto.scryptSync(String(raw), salt, 64).toString("hex");
    return expected.length === actual.length &&
      crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(actual));
  }

  // Backward compatibility for earlier SHA-256 hashes.
  return legacyHashPassword(raw) === value;
}

function normalizeAgencyName(name) {
  return String(name || "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, " ");
}

function normalizeStopName(name) {
  const raw = String(name || "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, " ");
  return STOP_ALIASES[raw] || raw;
}

function computeRouteSegment(origin, destination) {
  const fromKey = normalizeStopName(origin);
  const toKey = normalizeStopName(destination);
  const fromIndex = CORRIDOR_STOPS.indexOf(fromKey);
  const toIndex = CORRIDOR_STOPS.indexOf(toKey);
  if (fromIndex === -1 || toIndex === -1 || fromIndex === toIndex) {
    return {
      originKey: fromKey,
      destinationKey: toKey,
      originStopIndex: fromIndex,
      destinationStopIndex: toIndex,
      direction: "unknown",
      valid: false,
    };
  }
  return {
    originKey: fromKey,
    destinationKey: toKey,
    originStopIndex: fromIndex,
    destinationStopIndex: toIndex,
    direction: fromIndex < toIndex ? "forward" : "reverse",
    valid: true,
  };
}

function routeSegmentFromData(routeData) {
  const from = Number(routeData?.originStopIndex);
  const to = Number(routeData?.destinationStopIndex);
  const dir = String(routeData?.direction || "");
  const fromKey = String(routeData?.originKey || "");
  const toKey = String(routeData?.destinationKey || "");
  const hasStored = Number.isInteger(from) && Number.isInteger(to) && from !== to &&
    (dir === "forward" || dir === "reverse");
  if (hasStored) {
    return {
      originKey: fromKey,
      destinationKey: toKey,
      originStopIndex: from,
      destinationStopIndex: to,
      direction: dir,
      valid: true,
    };
  }
  return computeRouteSegment(routeData?.origin, routeData?.destination);
}

function bookingSegmentFromData(bookingData) {
  const from = Number(bookingData?.originStopIndex);
  const to = Number(bookingData?.destinationStopIndex);
  const dir = String(bookingData?.direction || "");
  if (Number.isInteger(from) && Number.isInteger(to) && from !== to &&
      (dir === "forward" || dir === "reverse")) {
    return {
      originStopIndex: from,
      destinationStopIndex: to,
      direction: dir,
      valid: true,
    };
  }
  const fallback = computeRouteSegment(
    bookingData?.routeOrigin || bookingData?.origin,
    bookingData?.routeDestination || bookingData?.destination,
  );
  if (fallback.valid) {
    return {
      originStopIndex: fallback.originStopIndex,
      destinationStopIndex: fallback.destinationStopIndex,
      direction: fallback.direction,
      valid: true,
    };
  }
  return {originStopIndex: -1, destinationStopIndex: -1, direction: "unknown", valid: false};
}

function isSeatConflictForRoute({existingBooking, requestSegment, nowMillis}) {
  const currentCycle = Number(requestSegment?.tripCycle ?? 0);
  const bookingCycle = Number(existingBooking?.tripCycle ?? 0);
  if (bookingCycle !== currentCycle) {
    return false;
  }

  const status = String(existingBooking?.status || "");
  if (status === BOOKING_STATUS.BOOKED) return true;
  if (status !== BOOKING_STATUS.PAID) return false;
  if (existingBooking?.seatReleased === true) return false;

  const existingSegment = bookingSegmentFromData(existingBooking);
  if (!existingSegment.valid || !requestSegment.valid) {
    // When route metadata is incomplete, stay safe and block overlap.
    return true;
  }

  if (existingSegment.direction !== requestSegment.direction) {
    // Reverse-direction reuse is blocked until a dedicated turnaround signal is added.
    return true;
  }

  const unlockAtMillis = existingBooking?.segmentUnlockAt?.toMillis?.() ||
    ((existingBooking?.paidAt?.toMillis?.() || existingBooking?.updatedAt?.toMillis?.() || 0) + SEAT_SEGMENT_UNLOCK_MS);
  if (unlockAtMillis > 0 && nowMillis < unlockAtMillis) {
    return true;
  }

  if (requestSegment.direction === "forward") {
    return requestSegment.originStopIndex < existingSegment.destinationStopIndex;
  }
  return requestSegment.originStopIndex > existingSegment.destinationStopIndex;
}

function readableUserName(data) {
  return String(data?.displayName || data?.name || data?.username || "").trim();
}

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

async function resolveAgencyIdByName(agencyName) {
  const nameLower = normalizeAgencyName(agencyName);
  if (!nameLower) return "";

  const byLower = await db.collection("agencies")
    .where("nameLower", "==", nameLower)
    .limit(1)
    .get();
  if (!byLower.empty) return byLower.docs[0].id;

  const byName = await db.collection("agencies")
    .where("name", "==", String(agencyName || "").trim())
    .limit(1)
    .get();
  if (!byName.empty) return byName.docs[0].id;

  return "";
}

async function upsertDiscoveredBusRecord({busId, payload, onlyAgencyId = ""}) {
  const agencyName = String(payload?.agencyName || "").trim();
  const plateNumber = String(payload?.plateNumber || "").trim();
  const deviceSecret = String(payload?.deviceSecret || "").trim();
  const seats = Number(payload?.sits || 0);
  if (!busId || !agencyName) return {updated: false, agencyId: ""};

  const agencyId = await resolveAgencyIdByName(agencyName);
  if (onlyAgencyId && agencyId !== onlyAgencyId) {
    return {updated: false, agencyId};
  }
  const now = admin.firestore.Timestamp.now();
  const busRef = db.collection("buses").doc(busId);
  const existing = await busRef.get();
  const existingData = existing.data() || {};

  const data = {
    agencyName,
    ...(agencyId ? {agencyId} : {}),
    ...(plateNumber ? {plateNumber} : {}),
    ...(deviceSecret ? {deviceSecret} : {}),
    active: true,
    autoDiscovered: true,
    updatedAt: now,
  };

  if (!existing.exists) {
    await busRef.set({
      ...data,
      capacity: seats > 0 ? seats : 30,
      availableSeats: seats > 0 ? seats : 30,
      routeId: String(existingData.routeId || ""),
      createdAt: now,
    }, {merge: true});
    return {updated: true, agencyId};
  }

  await busRef.set(data, {merge: true});
  return {updated: true, agencyId};
}

/**
 * Auto-discover buses from RTDB device nodes.
 * Triggered once when /devices/{busId} is first created.
 */
exports.syncDiscoveredBus = onValueCreated(
  {region: "us-central1", ref: "/devices/{busId}"},
  async (event) => {
    const busId = String(event.params.busId || "").trim();
    const after = event.data.val();
    if (!busId || !after || typeof after !== "object") return;
    await upsertDiscoveredBusRecord({busId, payload: after});
  },
);

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

exports.backfillDiscoveredBuses = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }

  const isSuper = isSuperAdminAuth(request);
  let allowedAgencyId = "";
  if (!isSuper) {
    const member = await getAgencyMembership(request.auth.uid);
    allowedAgencyId = member.agencyId;
  }

  const snap = await admin.database().ref("devices").once("value");
  const root = snap.val() || {};
  let scanned = 0;
  let updated = 0;

  for (const [busId, value] of Object.entries(root)) {
    if (!value || typeof value !== "object") continue;
    scanned += 1;
    const result = await upsertDiscoveredBusRecord({
      busId: String(busId),
      payload: value,
      onlyAgencyId: isSuper ? "" : allowedAgencyId,
    });
    if (!result.updated) continue;
    updated += 1;
  }

  return {ok: true, scanned, updated};
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

/**
 * Shared booking handler for v2 callable + v1 fallback callable.
 * request shape: { auth?: { uid?: string }, data?: {...} }
 */
async function handleBookSeat(request) {
  const uid = String(request.auth?.uid || "").trim();
  if (!uid) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  await assertUserIsActive(uid);
  const busId = String(request.data?.busId || "").trim();
  const routeId = String(request.data?.routeId || "").trim();
  const cardId = String(request.data?.cardId || "").trim();
  const idempotencyKey = String(request.data?.idempotencyKey || "").trim();
  const seatNo = Number(request.data?.seatNo || 0);

  if (!busId || !routeId || !cardId || !idempotencyKey || !seatNo) {
    throw new HttpsError("invalid-argument", "Missing required fields.");
  }

  const now = admin.firestore.Timestamp.now();
  const bookingRef = db.collection("bookings").doc();
  const busRef = db.collection("buses").doc(busId);
  const routeRef = db.collection("routes").doc(routeId);
  const cardRef = db.collection("cards").doc(cardId);
  const userRef = db.collection("users").doc(uid);

  const response = await db.runTransaction(async (tx) => {
    const [busSnap, routeSnap, cardSnap, userSnap] = await Promise.all([
      tx.get(busRef),
      tx.get(routeRef),
      tx.get(cardRef),
      tx.get(userRef),
    ]);

    if (!busSnap.exists) throw new HttpsError("not-found", "Bus not found.");
    if (!routeSnap.exists) throw new HttpsError("not-found", "Route not found.");
    if (!cardSnap.exists) throw new HttpsError("not-found", "Card not found.");

    const bus = busSnap.data();
    const route = routeSnap.data();
    const card = cardSnap.data();
    const user = userSnap.data() || {};

    if (!bus?.active) throw new HttpsError("failed-precondition", "Bus inactive.");
    if (!route?.active) throw new HttpsError("failed-precondition", "Route inactive.");
    if (!card?.active) throw new HttpsError("failed-precondition", "Card inactive.");
    const busPrimaryRouteId = String(bus.routeId || "");
    const busRouteIds = Array.isArray(bus.routeIds) ?
      bus.routeIds.map((v) => String(v || "").trim()).filter((v) => v.length > 0) :
      [];
    const supportsRoute = busPrimaryRouteId === routeId || busRouteIds.includes(routeId);
    if (!supportsRoute) {
      throw new HttpsError("failed-precondition", "Bus not assigned to selected direction.");
    }

    const fareRwf = Number(route.fareRwf || 0);
    const availableSeats = Number(bus.availableSeats || 0);
    const balanceRwf = Number(card.balanceRwf || 0);
    const bookingUserName = readableUserName(user);
    const cardOwnerUid = String(card.userId || "");
    let cardOwnerName = "";
    if (cardOwnerUid) {
      if (cardOwnerUid === uid) {
        cardOwnerName = bookingUserName;
      } else {
        const ownerSnap = await tx.get(db.collection("users").doc(cardOwnerUid));
        cardOwnerName = readableUserName(ownerSnap.data() || {});
      }
    }
    const usedExternalCard = Boolean(cardOwnerUid && cardOwnerUid !== uid);
    const routeOrigin = String(route.origin || "");
    const routeDestination = String(route.destination || "");
    const routeLabel = `${routeOrigin} -> ${routeDestination}`.trim();
    const requestSegment = routeSegmentFromData(route);
    const busDirection = String(bus.currentDirection || "");
    const busTripCycle = Number.isFinite(Number(bus.tripCycle)) ? Number(bus.tripCycle) : 0;
    requestSegment.tripCycle = busTripCycle;

    if (availableSeats <= 0) {
      throw new HttpsError("failed-precondition", "No seats available.");
    }
    if (requestSegment.valid &&
        (busDirection === "forward" || busDirection === "reverse") &&
        busDirection !== requestSegment.direction) {
      throw new HttpsError(
        "failed-precondition",
        "Bus is currently running the opposite direction.",
      );
    }
    if (balanceRwf < fareRwf) {
      throw new HttpsError("failed-precondition", "Insufficient card balance.");
    }

    const dupQuery = db.collection("bookings")
      .where("idempotencyKey", "==", idempotencyKey)
      .where("userId", "==", uid)
      .limit(1);
    const dupSnap = await tx.get(dupQuery);
    if (!dupSnap.empty) {
      const existing = dupSnap.docs[0];
      const data = existing.data();
      return {
        bookingId: existing.id,
        status: data.status,
        fareRwf: Number(data.fareRwf || fareRwf),
        availableSeats: availableSeats,
      };
    }

    const seatQuery = db.collection("bookings")
      .where("busId", "==", busId)
      .where("seatNo", "==", seatNo)
      .where("status", "in", [BOOKING_STATUS.BOOKED, BOOKING_STATUS.PAID])
      .limit(25);
    const seatSnap = await tx.get(seatQuery);
    const nowMillis = now.toMillis();
    const hasConflict = seatSnap.docs.some((doc) => isSeatConflictForRoute({
      existingBooking: doc.data(),
      requestSegment,
      nowMillis,
    }));
    if (hasConflict) {
      throw new HttpsError("already-exists", "Seat already occupied/booked for this direction.");
    }

    tx.set(bookingRef, {
      userId: uid,
      cardId,
      busId,
      routeId,
      agencyId: String(bus.agencyId || ""),
      seatNo,
      fareRwf,
      status: BOOKING_STATUS.BOOKED,
      bookedAt: now,
      busArrivedAt: null,
      expiresAt: null,
      paidAt: null,
      plateNumber: String(bus.plateNumber || ""),
      agencyName: String(bus.agencyName || ""),
      idempotencyKey,
      userName: bookingUserName,
      bookingUserId: uid,
      bookingUserName: bookingUserName,
      cardOwnerUid,
      cardOwnerName,
      usedExternalCard,
      routeOrigin,
      routeDestination,
      routeLabel,
      originKey: requestSegment.originKey,
      destinationKey: requestSegment.destinationKey,
      originStopIndex: requestSegment.originStopIndex,
      destinationStopIndex: requestSegment.destinationStopIndex,
      direction: requestSegment.direction,
      tripCycle: busTripCycle,
      seatReleased: false,
      segmentUnlockAt: null,
      createdAt: now,
      updatedAt: now,
    });

    tx.set(db.collection("card_transactions").doc(), {
      cardId,
      userId: cardOwnerUid || uid,
      bookingUserId: uid,
      bookingUserName: bookingUserName,
      cardOwnerUid,
      cardOwnerName,
      usedExternalCard,
      agencyId: String(bus.agencyId || ""),
      bookingId: bookingRef.id,
      type: "BOOKED",
      amountDeltaRwf: 0,
      balanceAfterRwf: balanceRwf,
      note: usedExternalCard ?
        `Seat ${seatNo} reserved by ${bookingUserName || uid} using card owner ${cardOwnerName || cardOwnerUid}` :
        `Seat ${seatNo} reserved on bus ${busId}`,
      createdAt: now,
    });

    tx.update(busRef, {
      availableSeats: admin.firestore.FieldValue.increment(-1),
      ...(requestSegment.valid && (!busDirection || busDirection === "unknown") ? {currentDirection: requestSegment.direction} : {}),
      updatedAt: now,
    });

      tx.set(db.collection("booking_events").doc(), {
        bookingId: bookingRef.id,
        agencyId: String(bus.agencyId || ""),
        type: "BOOKED",
        source: "app",
      payload: {uid, busId, routeId, seatNo},
      createdAt: now,
    });

    return {
      bookingId: bookingRef.id,
      status: BOOKING_STATUS.BOOKED,
      fareRwf,
      availableSeats: availableSeats - 1,
    };
  });

  return {ok: true, ...response};
}

/**
 * Client callable (v2):
 * data: { busId, routeId, cardId, seatNo, idempotencyKey }
 */
exports.bookSeat = onCall({
  region: "us-central1",
  invoker: "public",
  enforceAppCheck: false,
}, async (request) => handleBookSeat(request));

/**
 * Fallback callable (v1):
 * keeps same payload and response as bookSeat.
 */
exports.bookSeatV1 = functionsV1.region("us-central1").https.onCall(async (data, context) => {
  return handleBookSeat({data, auth: context.auth});
});

exports.registerCardToUser = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const uid = request.auth.uid;
  const {agencyId, role} = await getAgencyMembership(uid);
  assertRole(role, ["agency_admin", "agency_staff"]);

  const cardId = String(request.data?.cardId || "").trim();
  const userId = String(request.data?.userId || "").trim();
  const active = request.data?.active !== false;
  const initialBalanceRwf = Number(request.data?.initialBalanceRwf || 0);
  const allowExistingForSameUser = request.data?.allowExistingForSameUser !== false;

  if (!cardId || !userId) {
    throw new HttpsError("invalid-argument", "cardId and userId are required.");
  }
  if (!Number.isFinite(initialBalanceRwf) || initialBalanceRwf < 0) {
    throw new HttpsError("invalid-argument", "initialBalanceRwf must be >= 0.");
  }

  const now = admin.firestore.Timestamp.now();
  const cardRef = db.collection("cards").doc(cardId);
  const userRef = db.collection("users").doc(userId);

  await db.runTransaction(async (tx) => {
    const [userSnap, cardSnap] = await Promise.all([tx.get(userRef), tx.get(cardRef)]);
    if (!userSnap.exists) {
      throw new HttpsError("not-found", "User not found.");
    }
    const user = userSnap.data() || {};
    if (user.isActive === false) {
      throw new HttpsError("failed-precondition", "User is inactive.");
    }
    const ownerName = readableUserName(user);

    if (cardSnap.exists) {
      const card = cardSnap.data() || {};
      const owner = String(card.userId || "");
      if (owner && owner !== userId) {
        throw new HttpsError("already-exists", "Card is already assigned to another user.");
      }
      if (!allowExistingForSameUser) {
        throw new HttpsError("already-exists", "Card already exists.");
      }
      tx.set(cardRef, {
        userId,
        ownerName,
        active,
        issuerAgencyId: agencyId,
        updatedAt: now,
      }, {merge: true});
      return;
    }

    tx.set(cardRef, {
      userId,
      ownerName,
      balanceRwf: initialBalanceRwf,
      active,
      issuerAgencyId: agencyId,
      createdAt: now,
      updatedAt: now,
    }, {merge: true});
  });

  await writeAdminEvent({
    agencyId,
    actorId: uid,
    actorRole: role,
    type: "CARD_REGISTERED",
    description: `Registered card ${cardId} to user ${userId}`,
    payload: {cardId, userId, initialBalanceRwf},
  });

  return {ok: true, cardId, userId};
});

/**
 * Device endpoint from ESP32:
 * body: { busId, cardId, plateNumber, deviceTs, deviceSecret }
 */
exports.tapCard = onRequest({region: "us-central1"}, async (req, res) => {
  if (req.method !== "POST") {
    res.status(405).json({ok: false, error: "Method not allowed"});
    return;
  }

  try {
    const busId = String(req.body?.busId || "").trim();
    const cardId = String(req.body?.cardId || "").trim();
    const plateNumber = String(req.body?.plateNumber || "").trim();
    const deviceSecret = String(req.body?.deviceSecret || "").trim();

    if (!busId || !cardId || !deviceSecret) {
      res.status(400).json({ok: false, error: "Missing required fields"});
      return;
    }

    // Simple shared-secret verification per device.
    const busSnap = await db.collection("buses").doc(busId).get();
    if (!busSnap.exists) {
      res.status(404).json({ok: false, error: "Bus not found"});
      return;
    }
    const bus = busSnap.data() || {};
    if (String(bus.deviceSecret || "") !== deviceSecret) {
      res.status(403).json({ok: false, error: "Invalid device secret"});
      return;
    }
    if (bus.active === false) {
      res.status(400).json({ok: false, error: "Bus inactive"});
      return;
    }
    if (String(bus.agencyId || "").trim()) {
      await assertAgencyIsActive(String(bus.agencyId || "").trim());
    }

    const now = admin.firestore.Timestamp.now();
    const bookingQuery = db.collection("bookings")
      .where("busId", "==", busId)
      .where("cardId", "==", cardId)
      .where("status", "==", BOOKING_STATUS.BOOKED)
      .orderBy("bookedAt", "desc")
      .limit(1);
    const bookingSnap = await bookingQuery.get();

    if (bookingSnap.empty) {
      res.status(404).json({ok: false, error: "No active booking for card on this bus"});
      return;
    }

    const bookingDoc = bookingSnap.docs[0];
    const booking = bookingDoc.data();
    const bookingUserId = String(booking.bookingUserId || booking.userId || "").trim();
    if (bookingUserId) {
      await assertUserIsActive(bookingUserId);
    }
    const fareRwf = Number(booking.fareRwf || 0);
    const cardRef = db.collection("cards").doc(cardId);
    const bookingRef = bookingDoc.ref;

    const txResult = await db.runTransaction(async (tx) => {
      const [freshBookingSnap, cardSnap] = await Promise.all([
        tx.get(bookingRef),
        tx.get(cardRef),
      ]);

      if (!freshBookingSnap.exists) {
        throw new Error("Booking disappeared.");
      }
      if (!cardSnap.exists) {
        throw new Error("Card not found.");
      }

      const freshBooking = freshBookingSnap.data();
      const card = cardSnap.data();

      if (freshBooking.status !== BOOKING_STATUS.BOOKED) {
        throw new Error("Booking is no longer pending.");
      }

      const expiresAt = freshBooking.expiresAt;
      if (expiresAt && expiresAt.toMillis && expiresAt.toMillis() < now.toMillis()) {
        tx.update(bookingRef, {
          status: BOOKING_STATUS.EXPIRED,
          updatedAt: now,
        });
        tx.update(db.collection("buses").doc(busId), {
          availableSeats: admin.firestore.FieldValue.increment(1),
          updatedAt: now,
        });
        throw new Error("Booking expired.");
      }

      const balanceRwf = Number(card.balanceRwf || 0);
      if (balanceRwf < fareRwf) {
        throw new Error("Insufficient balance.");
      }

      tx.update(cardRef, {
        balanceRwf: admin.firestore.FieldValue.increment(-fareRwf),
        updatedAt: now,
      });
      const nextBalance = balanceRwf - fareRwf;
      tx.update(bookingRef, {
        status: BOOKING_STATUS.PAID,
        paidAt: now,
        segmentUnlockAt: admin.firestore.Timestamp.fromMillis(now.toMillis() + SEAT_SEGMENT_UNLOCK_MS),
        seatReleased: false,
        plateNumber: plateNumber || String(freshBooking.plateNumber || ""),
        updatedAt: now,
      });
      tx.set(db.collection("booking_events").doc(), {
        bookingId: bookingRef.id,
        agencyId: String(bus.agencyId || ""),
        type: "PAID",
        source: "device",
        payload: {busId, cardId, plateNumber},
        createdAt: now,
      });

      tx.set(db.collection("card_transactions").doc(), {
        cardId,
        userId: String(freshBooking.cardOwnerUid || card.userId || freshBooking.userId || ""),
        bookingUserId: String(freshBooking.bookingUserId || freshBooking.userId || ""),
        bookingUserName: String(freshBooking.bookingUserName || freshBooking.userName || ""),
        cardOwnerUid: String(freshBooking.cardOwnerUid || card.userId || ""),
        cardOwnerName: String(freshBooking.cardOwnerName || ""),
        usedExternalCard: Boolean(freshBooking.usedExternalCard === true),
        agencyId: String(bus.agencyId || ""),
        bookingId: bookingRef.id,
        type: "PAID",
        amountDeltaRwf: -fareRwf,
        balanceAfterRwf: nextBalance,
        note: `Paid fare on bus ${busId} (${String(freshBooking.routeLabel || freshBooking.routeId || "")}) by ${String(freshBooking.bookingUserName || freshBooking.userName || freshBooking.userId || "")}`,
        createdAt: now,
      });

      return {newBalanceRwf: balanceRwf - fareRwf};
    });

    res.status(200).json({
      ok: true,
      bookingId: bookingRef.id,
      status: BOOKING_STATUS.PAID,
      ...txResult,
    });
  } catch (err) {
    logger.error("tapCard error", err);
    res.status(400).json({ok: false, error: err.message || "tapCard failed"});
  }
});

/**
 * Scheduled cleanup every minute:
 * expires bookings where status=booked and expiresAt <= now
 */
exports.expireBookings = onSchedule(
  {region: "us-central1", schedule: "every 1 minutes"},
  async () => {
    const now = admin.firestore.Timestamp.now();
    const query = db.collection("bookings")
      .where("status", "==", BOOKING_STATUS.BOOKED)
      .where("expiresAt", "<=", now)
      .limit(200);

    const snap = await query.get();
    if (snap.empty) return;

    for (const doc of snap.docs) {
      const data = doc.data();
      const busId = String(data.busId || "");
      if (!busId) continue;

      await db.runTransaction(async (tx) => {
        const fresh = await tx.get(doc.ref);
        if (!fresh.exists) return;
        const freshData = fresh.data();
        if (freshData.status !== BOOKING_STATUS.BOOKED) return;
        const exp = freshData.expiresAt;
        if (!exp || exp.toMillis() > now.toMillis()) return;

        tx.update(doc.ref, {
          status: BOOKING_STATUS.EXPIRED,
          updatedAt: now,
        });
        tx.update(db.collection("buses").doc(busId), {
          availableSeats: admin.firestore.FieldValue.increment(1),
          updatedAt: now,
        });
        tx.set(db.collection("booking_events").doc(), {
          bookingId: doc.id,
          agencyId: String(freshData.agencyId || ""),
          type: "EXPIRED",
          source: "cron",
          payload: {busId},
          createdAt: now,
        });
      });
    }
  },
);

/**
 * Releases paid seats after segment unlock time.
 * This makes seats available again for downstream same-direction bookings.
 */
exports.releasePaidSeats = onSchedule(
  {region: "us-central1", schedule: "every 1 minutes"},
  async () => {
    const now = admin.firestore.Timestamp.now();
    const query = db.collection("bookings")
      .where("status", "==", BOOKING_STATUS.PAID)
      .where("seatReleased", "==", false)
      .where("segmentUnlockAt", "<=", now)
      .limit(200);

    const snap = await query.get();
    if (snap.empty) return;

    for (const doc of snap.docs) {
      const data = doc.data() || {};
      const busId = String(data.busId || "");
      if (!busId) continue;
      const busRef = db.collection("buses").doc(busId);

      await db.runTransaction(async (tx) => {
        const [freshBooking, busSnap] = await Promise.all([
          tx.get(doc.ref),
          tx.get(busRef),
        ]);
        if (!freshBooking.exists || !busSnap.exists) return;
        const booking = freshBooking.data() || {};
        const bus = busSnap.data() || {};
        if (String(booking.status || "") !== BOOKING_STATUS.PAID) return;
        if (booking.seatReleased === true) return;
        const unlockAt = booking.segmentUnlockAt;
        if (!unlockAt || unlockAt.toMillis() > now.toMillis()) return;

        const capacity = Number(bus.capacity || 0);
        const currentAvailable = Number(bus.availableSeats || 0);
        const nextAvailable = capacity > 0 ?
          Math.min(capacity, currentAvailable + 1) :
          currentAvailable + 1;

        tx.update(doc.ref, {
          seatReleased: true,
          seatReleasedAt: now,
          updatedAt: now,
        });
        tx.update(busRef, {
          availableSeats: nextAvailable,
          updatedAt: now,
        });
        tx.set(db.collection("booking_events").doc(), {
          bookingId: doc.id,
          agencyId: String(booking.agencyId || ""),
          type: "SEAT_RELEASED",
          source: "cron",
          payload: {busId, seatNo: Number(booking.seatNo || 0)},
          createdAt: now,
        });
      });
    }
  },
);

exports.requestDirection = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const uid = request.auth.uid;
  const {agencyId, role} = await getAgencyMembership(uid);
  assertRole(role, ["agency_admin"]);

  const origin = String(request.data?.origin || "").trim();
  const destination = String(request.data?.destination || "").trim();
  const note = String(request.data?.note || "").trim();
  if (!origin || !destination) {
    throw new HttpsError("invalid-argument", "origin and destination are required.");
  }
  const directionKey = `${origin.toLowerCase()}::${destination.toLowerCase()}`;
  const now = admin.firestore.Timestamp.now();

  const agencySnap = await db.collection("agencies").doc(agencyId).get();
  const agencyName = String(agencySnap.data()?.name || agencyId);
  const userSnap = await db.collection("users").doc(uid).get();
  const requesterName = readableUserName(userSnap.data() || {}) || uid;
  const requesterEmail = String(userSnap.data()?.email || request.auth.token.email || "");

  const ref = await db.collection("direction_requests").add({
    agencyId,
    agencyName,
    requesterUid: uid,
    requesterName,
    requesterEmail,
    origin,
    destination,
    directionKey,
    note,
    status: "pending",
    createdAt: now,
    updatedAt: now,
  });

  await writeAdminEvent({
    agencyId,
    actorId: uid,
    actorRole: role,
    type: "DIRECTION_REQUESTED",
    description: `Requested direction ${origin} -> ${destination}`,
    payload: {requestId: ref.id, origin, destination},
  });

  return {ok: true, requestId: ref.id};
});

exports.resolveDirectionRequest = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  assertSuperAdmin(request);

  const requestId = String(request.data?.requestId || "").trim();
  const approve = request.data?.approve === true;
  const fareRwf = Number(request.data?.fareRwf || 0);
  if (!requestId) {
    throw new HttpsError("invalid-argument", "requestId is required.");
  }
  if (approve && (!Number.isFinite(fareRwf) || fareRwf < 0)) {
    throw new HttpsError("invalid-argument", "fareRwf must be >= 0.");
  }

  const now = admin.firestore.Timestamp.now();
  const uid = request.auth.uid;
  const ref = db.collection("direction_requests").doc(requestId);
  const snap = await ref.get();
  if (!snap.exists) {
    throw new HttpsError("not-found", "Direction request not found.");
  }
  const req = snap.data() || {};
  if (String(req.status || "") !== "pending") {
    return {ok: true, alreadyHandled: true};
  }

  if (approve) {
    const origin = String(req.origin || "").trim();
    const destination = String(req.destination || "").trim();
    const directionKey = String(req.directionKey || `${origin.toLowerCase()}::${destination.toLowerCase()}`);
    const segment = computeRouteSegment(origin, destination);
    const routeRef = db.collection("routes").doc();
    await routeRef.set({
      agencyId: "",
      global: true,
      directionKey,
      origin,
      destination,
      originKey: segment.originKey,
      destinationKey: segment.destinationKey,
      originStopIndex: segment.originStopIndex,
      destinationStopIndex: segment.destinationStopIndex,
      direction: segment.direction,
      fareRwf,
      active: true,
      createdAt: now,
      updatedAt: now,
    }, {merge: true});
    await ref.set({
      status: "approved",
      resolvedBy: uid,
      resolvedAt: now,
      updatedAt: now,
      approvedRouteId: routeRef.id,
      approvedFareRwf: fareRwf,
    }, {merge: true});
    return {ok: true, status: "approved", routeId: routeRef.id};
  }

  await ref.set({
    status: "rejected",
    resolvedBy: uid,
    resolvedAt: now,
    updatedAt: now,
  }, {merge: true});
  return {ok: true, status: "rejected"};
});

async function getAgencyMembership(uid) {
  await assertUserIsActive(uid);
  const memberRef = db.collection("agency_members").doc(uid);
  const snap = await memberRef.get();
  if (!snap.exists) {
    throw new HttpsError("permission-denied", "No agency membership found.");
  }
  const d = snap.data() || {};
  if (d.active !== true) {
    throw new HttpsError("permission-denied", "Agency membership is inactive.");
  }
  const agencyIdRaw = String(d.agencyId || "");
  const role = String(d.role || "").trim().toLowerCase();
  if (!agencyIdRaw || !role) {
    throw new HttpsError("permission-denied", "Invalid agency membership.");
  }
  const agencyId = await resolveAgencyIdRef(agencyIdRaw);
  if (agencyId !== agencyIdRaw) {
    await memberRef.set({
      agencyId,
      updatedAt: admin.firestore.Timestamp.now(),
    }, {merge: true});
  }
  await assertAgencyIsActive(agencyId);
  return {agencyId, role};
}

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

async function assertAgencyIsActive(agencyId) {
  const canonicalAgencyId = await resolveAgencyIdRef(agencyId);
  const agencySnap = await db.collection("agencies").doc(String(canonicalAgencyId || "")).get();
  if (!agencySnap.exists) {
    throw new HttpsError("not-found", "Agency not found.");
  }
  const agency = agencySnap.data() || {};
  if (agency.active === false) {
    throw new HttpsError("failed-precondition", "Agency is inactive.");
  }
}

async function resolveAgencyIdRef(agencyRef) {
  const raw = String(agencyRef || "").trim();
  if (!raw) {
    throw new HttpsError("invalid-argument", "Agency reference is required.");
  }

  const byId = await db.collection("agencies").doc(raw).get();
  if (byId.exists) return raw;

  const lowerName = normalizeAgencyName(raw);
  if (lowerName) {
    const byLower = await db.collection("agencies")
      .where("nameLower", "==", lowerName)
      .limit(1)
      .get();
    if (!byLower.empty) return byLower.docs[0].id;
  }

  const byCode = await db.collection("agencies")
    .where("code", "==", raw.toUpperCase())
    .limit(1)
    .get();
  if (!byCode.empty) return byCode.docs[0].id;

  const byName = await db.collection("agencies")
    .where("name", "==", raw)
    .limit(1)
    .get();
  if (!byName.empty) return byName.docs[0].id;

  throw new HttpsError("not-found", "Agency not found.");
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

function assertRole(role, allowed) {
  const normalizedRole = String(role || "").trim().toLowerCase();
  if (!allowed.includes(normalizedRole)) {
    throw new HttpsError("permission-denied", "Insufficient role permissions.");
  }
}

async function writeAdminEvent({agencyId, actorId, actorRole, type, description, payload}) {
  let actorName = "";
  if (actorId) {
    try {
      const actorSnap = await db.collection("users").doc(actorId).get();
      actorName = readableUserName(actorSnap.data() || {});
    } catch (_) {
      actorName = "";
    }
  }
  await db.collection("admin_events").add({
    agencyId,
    actorId,
    actorName,
    actorRole,
    type,
    description,
    payload: payload || {},
    createdAt: admin.firestore.Timestamp.now(),
  });
}

function computeSplit(fareRwf) {
  const fare = Math.max(0, Number(fareRwf || 0));
  const spotlightShare = Math.round((fare * SPOTLIGHT_REVENUE_SHARE_PERCENT) / 100);
  const agencyShare = fare - spotlightShare;
  return {fare, spotlightShare, agencyShare};
}

async function getSpotlightBankAccount() {
  const snap = await db.collection("system_settings").doc("finance").get();
  if (!snap.exists) return SPOTLIGHT_BANK_ACCOUNT;
  const data = snap.data() || {};
  const bank = data.spotlightBank || {};
  return {
    accountName: String(bank.accountName || SPOTLIGHT_BANK_ACCOUNT.accountName),
    bankName: String(bank.bankName || SPOTLIGHT_BANK_ACCOUNT.bankName),
    accountNumber: String(bank.accountNumber || SPOTLIGHT_BANK_ACCOUNT.accountNumber),
  };
}

async function aggregatePaidBookings({agencyId = ""} = {}) {
  const statusPaid = BOOKING_STATUS.PAID;
  let query = db.collection("bookings")
    .where("status", "==", statusPaid)
    .orderBy("paidAt", "desc")
    .limit(500);
  if (agencyId) {
    query = query.where("agencyId", "==", agencyId);
  }

  let lastDoc = null;
  let processed = 0;
  let totalFareRwf = 0;
  let totalSpotlightShareRwf = 0;
  let totalAgencyShareRwf = 0;

  while (true) {
    const snap = lastDoc ? await query.startAfter(lastDoc).get() : await query.get();
    if (snap.empty) break;

    for (const doc of snap.docs) {
      const b = doc.data() || {};
      const split = computeSplit(b.fareRwf);
      totalFareRwf += split.fare;
      totalSpotlightShareRwf += split.spotlightShare;
      totalAgencyShareRwf += split.agencyShare;
      processed += 1;
    }
    lastDoc = snap.docs[snap.docs.length - 1];
    if (snap.size < 500) break;
  }

  return {
    paidBookings: processed,
    totalFareRwf,
    totalSpotlightShareRwf,
    totalAgencyShareRwf,
  };
}

async function aggregatePaidBookingsByAgency() {
  const statusPaid = BOOKING_STATUS.PAID;
  const query = db.collection("bookings")
    .where("status", "==", statusPaid)
    .orderBy("paidAt", "desc")
    .limit(500);

  let lastDoc = null;
  const grouped = new Map();

  while (true) {
    const snap = lastDoc ? await query.startAfter(lastDoc).get() : await query.get();
    if (snap.empty) break;
    for (const doc of snap.docs) {
      const b = doc.data() || {};
      const agencyId = String(b.agencyId || "").trim();
      if (!agencyId) continue;
      const split = computeSplit(b.fareRwf);
      const prev = grouped.get(agencyId) || {
        paidBookings: 0,
        totalFareRwf: 0,
        totalSpotlightShareRwf: 0,
        totalAgencyShareRwf: 0,
      };
      grouped.set(agencyId, {
        paidBookings: prev.paidBookings + 1,
        totalFareRwf: prev.totalFareRwf + split.fare,
        totalSpotlightShareRwf: prev.totalSpotlightShareRwf + split.spotlightShare,
        totalAgencyShareRwf: prev.totalAgencyShareRwf + split.agencyShare,
      });
    }
    lastDoc = snap.docs[snap.docs.length - 1];
    if (snap.size < 500) break;
  }
  return grouped;
}

exports.createOrUpdateRoute = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  if (!isSuperAdminAuth(request)) {
    throw new HttpsError(
      "permission-denied",
      "Only super admin can create/update master directions.",
    );
  }
  const uid = request.auth.uid;

  const routeId = String(request.data?.routeId || "").trim();
  const origin = String(request.data?.origin || "").trim();
  const destination = String(request.data?.destination || "").trim();
  const fareRwf = Number(request.data?.fareRwf || 0);
  const active = request.data?.active !== false;

  if (!origin || !destination || fareRwf < 0) {
    throw new HttpsError("invalid-argument", "Invalid route payload.");
  }
  const directionKey = `${origin.trim().toLowerCase()}::${destination.trim().toLowerCase()}`;
  const segment = computeRouteSegment(origin, destination);

  const now = admin.firestore.Timestamp.now();
  const ref = routeId
    ? db.collection("routes").doc(routeId)
    : db.collection("routes").doc();

  if (routeId) {
    const existing = await ref.get();
    if (existing.exists) {
      const d = existing.data() || {};
      const isGlobalRoute = d.global === true || String(d.agencyId || "") === "";
      if (!isGlobalRoute) {
        throw new HttpsError("permission-denied", "Only global directions can be edited here.");
      }
    }
  }

  await ref.set({
    agencyId: "",
    global: true,
    directionKey,
    origin,
    destination,
    originKey: segment.originKey,
    destinationKey: segment.destinationKey,
    originStopIndex: segment.originStopIndex,
    destinationStopIndex: segment.destinationStopIndex,
    direction: segment.direction,
    fareRwf,
    active,
    updatedAt: now,
    ...(routeId ? {} : {createdAt: now}),
  }, {merge: true});

  await writeAdminEvent({
    agencyId: "system",
    actorId: uid,
    actorRole: "super_admin",
    type: routeId ? "ROUTE_UPDATED" : "ROUTE_CREATED",
    description: `${origin} -> ${destination} (RWF ${fareRwf})`,
    payload: {routeId: ref.id},
  });

  return {ok: true, routeId: ref.id};
});

exports.deleteRoute = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  if (!isSuperAdminAuth(request)) {
    throw new HttpsError("permission-denied", "Only super admin can delete routes.");
  }

  const uid = request.auth.uid;
  const routeId = String(request.data?.routeId || "").trim();
  if (!routeId) {
    throw new HttpsError("invalid-argument", "routeId is required.");
  }

  const routeRef = db.collection("routes").doc(routeId);
  const routeSnap = await routeRef.get();
  if (!routeSnap.exists) {
    throw new HttpsError("not-found", "Route not found.");
  }
  const route = routeSnap.data() || {};
  const isGlobalRoute = route.global === true || String(route.agencyId || "") === "";
  if (!isGlobalRoute) {
    throw new HttpsError("permission-denied", "Only master/global routes can be deleted.");
  }

  const [primaryAssigned, extraAssigned, activeBooked, paidBookings] = await Promise.all([
    db.collection("buses").where("routeId", "==", routeId).limit(1).get(),
    db.collection("buses").where("routeIds", "array-contains", routeId).limit(1).get(),
    db.collection("bookings")
      .where("routeId", "==", routeId)
      .where("status", "==", BOOKING_STATUS.BOOKED)
      .limit(1)
      .get(),
    db.collection("bookings")
      .where("routeId", "==", routeId)
      .where("status", "==", BOOKING_STATUS.PAID)
      .limit(500)
      .get(),
  ]);

  if (!primaryAssigned.empty || !extraAssigned.empty) {
    throw new HttpsError(
      "failed-precondition",
      "Cannot delete route: it is still assigned to one or more buses.",
    );
  }
  const hasPaidNotReleased = paidBookings.docs.some((d) => d.data()?.seatReleased !== true);
  if (!activeBooked.empty || hasPaidNotReleased) {
    throw new HttpsError(
      "failed-precondition",
      "Cannot delete route: it has active booked/paid seats not released.",
    );
  }

  await routeRef.delete();
  await writeAdminEvent({
    agencyId: "system",
    actorId: uid,
    actorRole: "super_admin",
    type: "ROUTE_DELETED",
    description: `Deleted master route ${String(route.origin || "")} -> ${String(route.destination || "")}`,
    payload: {routeId},
  });

  return {ok: true, routeId};
});

exports.releaseBookingSeat = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const uid = request.auth.uid;
  const {agencyId, role} = await getAgencyMembership(uid);
  assertRole(role, ["agency_admin", "agency_staff"]);

  const bookingId = String(request.data?.bookingId || "").trim();
  if (!bookingId) {
    throw new HttpsError("invalid-argument", "bookingId is required.");
  }

  const now = admin.firestore.Timestamp.now();
  const bookingRef = db.collection("bookings").doc(bookingId);
  let releaseType = "";

  await db.runTransaction(async (tx) => {
    const bookingSnap = await tx.get(bookingRef);
    if (!bookingSnap.exists) {
      throw new HttpsError("not-found", "Booking not found.");
    }
    const booking = bookingSnap.data() || {};
    if (String(booking.agencyId || "") !== agencyId) {
      throw new HttpsError("permission-denied", "Booking belongs to another agency.");
    }

    const status = String(booking.status || "");
    const busId = String(booking.busId || "");
    if (!busId) {
      throw new HttpsError("failed-precondition", "Booking has no bus.");
    }
    const busRef = db.collection("buses").doc(busId);
    const busSnap = await tx.get(busRef);
    if (!busSnap.exists) {
      throw new HttpsError("not-found", "Bus not found.");
    }
    const bus = busSnap.data() || {};
    const capacity = Number(bus.capacity || 0);
    const currentAvailable = Number(bus.availableSeats || 0);
    const nextAvailable = capacity > 0 ? Math.min(capacity, currentAvailable + 1) : currentAvailable + 1;

    if (status === BOOKING_STATUS.BOOKED) {
      tx.update(bookingRef, {
        status: BOOKING_STATUS.CANCELLED,
        seatReleased: true,
        seatReleasedAt: now,
        releasedBy: uid,
        releaseRole: role,
        releaseReason: "manual_admin_release",
        updatedAt: now,
      });
      tx.update(busRef, {
        availableSeats: nextAvailable,
        updatedAt: now,
      });
      releaseType = "BOOKED_RELEASED";
    } else if (status === BOOKING_STATUS.PAID) {
      if (booking.seatReleased === true) {
        releaseType = "ALREADY_RELEASED";
        return;
      }
      tx.update(bookingRef, {
        seatReleased: true,
        seatReleasedAt: now,
        releasedBy: uid,
        releaseRole: role,
        releaseReason: "manual_admin_release",
        updatedAt: now,
      });
      tx.update(busRef, {
        availableSeats: nextAvailable,
        updatedAt: now,
      });
      releaseType = "PAID_RELEASED";
    } else {
      throw new HttpsError("failed-precondition", "Only booked/paid bookings can be released.");
    }

    tx.set(db.collection("booking_events").doc(), {
      bookingId,
      agencyId,
      type: releaseType,
      source: "admin",
      payload: {
        busId,
        seatNo: Number(booking.seatNo || 0),
        releasedBy: uid,
      },
      createdAt: now,
    });
  });

  await writeAdminEvent({
    agencyId,
    actorId: uid,
    actorRole: role,
    type: "BOOKING_SEAT_RELEASED",
    description: `Released seat for booking ${bookingId}`,
    payload: {bookingId, releaseType},
  });

  return {ok: true, bookingId, releaseType};
});

exports.backfillRouteSegments = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  assertSuperAdmin(request);
  const snap = await db.collection("routes").limit(500).get();
  if (snap.empty) return {ok: true, scanned: 0, updated: 0};
  const batch = db.batch();
  let updated = 0;
  for (const doc of snap.docs) {
    const r = doc.data() || {};
    const segment = routeSegmentFromData(r);
    if (!segment.valid) continue;
    batch.set(doc.ref, {
      originKey: segment.originKey,
      destinationKey: segment.destinationKey,
      originStopIndex: segment.originStopIndex,
      destinationStopIndex: segment.destinationStopIndex,
      direction: segment.direction,
      updatedAt: admin.firestore.Timestamp.now(),
    }, {merge: true});
    updated += 1;
  }
  if (updated > 0) await batch.commit();
  return {ok: true, scanned: snap.size, updated};
});

exports.assignRouteToBus = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const uid = request.auth.uid;
  const {agencyId, role} = await getAgencyMembership(uid);
  assertRole(role, ["agency_admin", "agency_staff"]);

  const busId = String(request.data?.busId || "").trim();
  const routeId = String(request.data?.routeId || "").trim();
  if (!busId || !routeId) {
    throw new HttpsError("invalid-argument", "Missing busId/routeId.");
  }

  const busRef = db.collection("buses").doc(busId);
  const routeRef = db.collection("routes").doc(routeId);
  const now = admin.firestore.Timestamp.now();

  await db.runTransaction(async (tx) => {
    const [busSnap, routeSnap] = await Promise.all([tx.get(busRef), tx.get(routeRef)]);
    if (!busSnap.exists || !routeSnap.exists) {
      throw new HttpsError("not-found", "Bus or route not found.");
    }
    const bus = busSnap.data() || {};
    const route = routeSnap.data() || {};
    const routeAgency = String(route.agencyId || "");
    const isGlobalRoute = route.global === true || routeAgency === "";
    if (String(bus.agencyId || "") !== agencyId || (!isGlobalRoute && routeAgency !== agencyId)) {
      throw new HttpsError("permission-denied", "Cross-agency assign is forbidden.");
    }

    const currentPrimary = String(bus.routeId || "");
    const currentRouteIds = Array.isArray(bus.routeIds) ?
      bus.routeIds.map((v) => String(v || "").trim()).filter((v) => v.length > 0) :
      [];
    const mergedRouteIds = Array.from(new Set([...currentRouteIds, routeId]));
    tx.update(busRef, {
      routeId: currentPrimary || routeId,
      routeIds: mergedRouteIds,
      updatedAt: now,
    });
  });

  await writeAdminEvent({
    agencyId,
    actorId: uid,
    actorRole: role,
    type: "BUS_ROUTE_ASSIGNED",
    description: `Assigned route ${routeId} to bus ${busId}`,
    payload: {busId, routeId},
  });

  return {ok: true};
});

exports.unassignRouteFromBus = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const uid = request.auth.uid;
  const {agencyId, role} = await getAgencyMembership(uid);
  assertRole(role, ["agency_admin", "agency_staff"]);

  const busId = String(request.data?.busId || "").trim();
  const routeId = String(request.data?.routeId || "").trim();
  if (!busId || !routeId) {
    throw new HttpsError("invalid-argument", "Missing busId/routeId.");
  }

  const busRef = db.collection("buses").doc(busId);
  const now = admin.firestore.Timestamp.now();

  await db.runTransaction(async (tx) => {
    const busSnap = await tx.get(busRef);
    if (!busSnap.exists) {
      throw new HttpsError("not-found", "Bus not found.");
    }
    const bus = busSnap.data() || {};
    if (String(bus.agencyId || "") !== agencyId) {
      throw new HttpsError("permission-denied", "Bus belongs to another agency.");
    }

    const primary = String(bus.routeId || "");
    const routeIds = Array.isArray(bus.routeIds) ?
      bus.routeIds.map((v) => String(v || "").trim()).filter((v) => v.length > 0) :
      [];
    const nextRouteIds = routeIds.filter((v) => v !== routeId);
    const nextPrimary = primary === routeId ?
      (nextRouteIds.length ? nextRouteIds[0] : "") :
      primary;

    tx.update(busRef, {
      routeId: nextPrimary,
      routeIds: nextRouteIds,
      updatedAt: now,
    });
  });

  await writeAdminEvent({
    agencyId,
    actorId: uid,
    actorRole: role,
    type: "BUS_ROUTE_UNASSIGNED",
    description: `Unassigned route ${routeId} from bus ${busId}`,
    payload: {busId, routeId},
  });

  return {ok: true};
});

exports.markBusTurnaround = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const uid = request.auth.uid;
  const busId = String(request.data?.busId || "").trim();
  const nextDirectionInput = String(request.data?.nextDirection || "").trim().toLowerCase();
  if (!busId) {
    throw new HttpsError("invalid-argument", "busId is required.");
  }
  if (nextDirectionInput && !["forward", "reverse"].includes(nextDirectionInput)) {
    throw new HttpsError("invalid-argument", "nextDirection must be forward or reverse.");
  }

  const isSuper = isSuperAdminAuth(request);
  let agencyId = "";
  let actorRole = "super_admin";
  if (!isSuper) {
    const member = await getAgencyMembership(uid);
    assertRole(member.role, ["agency_admin", "agency_staff"]);
    agencyId = member.agencyId;
    actorRole = member.role;
  }

  const now = admin.firestore.Timestamp.now();
  const busRef = db.collection("buses").doc(busId);

  await db.runTransaction(async (tx) => {
    const busSnap = await tx.get(busRef);
    if (!busSnap.exists) {
      throw new HttpsError("not-found", "Bus not found.");
    }
    const bus = busSnap.data() || {};
    const busAgencyId = String(bus.agencyId || "");
    if (!isSuper && busAgencyId !== agencyId) {
      throw new HttpsError("permission-denied", "Bus belongs to another agency.");
    }

    const currentDirection = String(bus.currentDirection || "");
    const nextDirection = nextDirectionInput ||
      (currentDirection === "forward" ? "reverse" : "forward");
    const tripCycle = Number.isFinite(Number(bus.tripCycle)) ? Number(bus.tripCycle) : 0;
    const capacity = Number(bus.capacity || 0);
    const nextAvailableSeats = capacity > 0 ? capacity : Number(bus.availableSeats || 0);

    tx.update(busRef, {
      currentDirection: nextDirection,
      tripCycle: tripCycle + 1,
      availableSeats: nextAvailableSeats,
      lastTurnaroundAt: now,
      updatedAt: now,
    });
  });

  // Close stale pending bookings from previous cycle so tapCard can't charge old trips.
  const freshBusSnap = await busRef.get();
  const currentCycle = Number(freshBusSnap.data()?.tripCycle || 0);
  const staleBookedSnap = await db.collection("bookings")
    .where("busId", "==", busId)
    .where("status", "==", BOOKING_STATUS.BOOKED)
    .limit(300)
    .get();
  if (!staleBookedSnap.empty) {
    const batch = db.batch();
    let touched = 0;
    for (const d of staleBookedSnap.docs) {
      const b = d.data() || {};
      const bookingCycle = Number.isFinite(Number(b.tripCycle)) ? Number(b.tripCycle) : 0;
      if (bookingCycle >= currentCycle) continue;
      batch.update(d.ref, {
        status: BOOKING_STATUS.EXPIRED,
        updatedAt: now,
        expiredReason: "bus_turnaround",
      });
      touched += 1;
    }
    if (touched > 0) {
      await batch.commit();
    }
  }

  await writeAdminEvent({
    agencyId: isSuper ? "system" : agencyId,
    actorId: uid,
    actorRole,
    type: "BUS_TURNAROUND",
    description: `Bus ${busId} marked turnaround.`,
    payload: {busId, nextDirection: nextDirectionInput || "auto"},
  });

  return {ok: true, busId};
});

exports.createOrUpdateBus = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const uid = request.auth.uid;
  const {agencyId, role} = await getAgencyMembership(uid);
  // Bus profile creation/edit is sensitive and stays admin-only.
  assertRole(role, ["agency_admin"]);

  const busId = String(request.data?.busId || "").trim();
  const agencyName = String(request.data?.agencyName || "").trim();
  const plateNumber = String(request.data?.plateNumber || "").trim();
  const routeId = String(request.data?.routeId || "").trim();
  const routeIdsInput = Array.isArray(request.data?.routeIds) ? request.data.routeIds : [];
  const routeIds = Array.from(new Set([
    ...routeIdsInput.map((v) => String(v || "").trim()).filter((v) => v.length > 0),
    ...(routeId ? [routeId] : []),
  ]));
  const active = request.data?.active !== false;
  const capacity = Number(request.data?.capacity || 30);
  const availableSeats = Number(request.data?.availableSeats || 0);
  const deviceSecret = String(request.data?.deviceSecret || "").trim();

  if (!busId) {
    throw new HttpsError("invalid-argument", "busId is required.");
  }
  if (!Number.isFinite(capacity) || capacity <= 0) {
    throw new HttpsError("invalid-argument", "capacity must be > 0.");
  }
  if (!Number.isFinite(availableSeats) || availableSeats < 0 || availableSeats > capacity) {
    throw new HttpsError(
      "invalid-argument",
      "availableSeats must be between 0 and capacity.",
    );
  }

  for (const oneRouteId of routeIds) {
    const routeSnap = await db.collection("routes").doc(oneRouteId).get();
    if (!routeSnap.exists) {
      throw new HttpsError("not-found", `Route not found: ${oneRouteId}`);
    }
    const route = routeSnap.data() || {};
    const routeAgency = String(route.agencyId || "");
    const isGlobalRoute = route.global === true || routeAgency === "";
    if (!isGlobalRoute && routeAgency !== agencyId) {
      throw new HttpsError("permission-denied", "Route belongs to another agency.");
    }
  }

  const now = admin.firestore.Timestamp.now();
  const ref = db.collection("buses").doc(busId);
  const existingSnap = await ref.get();
  const existing = existingSnap.data() || {};
  await ref.set({
    agencyId,
    agencyName: agencyName || "Agency Bus",
    plateNumber,
    routeId: routeId || (routeIds.length ? routeIds[0] : ""),
    routeIds,
    capacity,
    availableSeats,
    currentDirection: String(existing.currentDirection || "unknown"),
    tripCycle: Number.isFinite(Number(existing.tripCycle)) ? Number(existing.tripCycle) : 0,
    active,
    ...(deviceSecret ? {deviceSecret} : {}),
    ...(existingSnap.exists ? {} : {createdAt: now}),
    updatedAt: now,
  }, {merge: true});

  await writeAdminEvent({
    agencyId,
    actorId: uid,
    actorRole: role,
    type: "BUS_UPSERT",
    description: `Bus ${busId} saved (${plateNumber || "no plate"})`,
    payload: {busId, routeId},
  });

  return {ok: true, busId};
});

exports.topUpCard = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const uid = request.auth.uid;
  const {agencyId, role} = await getAgencyMembership(uid);
  assertRole(role, ["agency_admin", "agency_staff"]);

  const cardId = String(request.data?.cardId || "").trim();
  const amountRwf = Number(request.data?.amountRwf || 0);
  if (!cardId || !Number.isFinite(amountRwf) || amountRwf <= 0) {
    throw new HttpsError("invalid-argument", "Invalid top up payload.");
  }

  const cardRef = db.collection("cards").doc(cardId);
  const now = admin.firestore.Timestamp.now();

  const newBalance = await db.runTransaction(async (tx) => {
    const snap = await tx.get(cardRef);
    if (!snap.exists) {
      throw new HttpsError("not-found", "Card not found.");
    }
    const card = snap.data() || {};
    if (card.active !== true) {
      throw new HttpsError("failed-precondition", "Card inactive.");
    }
    const ownerUid = String(card.userId || "");
    let ownerName = "";
    if (ownerUid) {
      const ownerSnap = await tx.get(db.collection("users").doc(ownerUid));
      ownerName = readableUserName(ownerSnap.data() || {});
    }
    const prev = Number(card.balanceRwf || 0);
    const next = prev + amountRwf;
    tx.update(cardRef, {
      balanceRwf: next,
      updatedAt: now,
      lastTopupAt: now,
    });
    tx.set(db.collection("card_transactions").doc(), {
      cardId,
      userId: ownerUid,
      cardOwnerUid: ownerUid,
      cardOwnerName: ownerName,
      agencyId,
      type: "TOPUP",
      amountDeltaRwf: amountRwf,
      balanceAfterRwf: next,
      note: "Cash top up by agency staff/admin",
      createdAt: now,
      actorUid: uid,
      actorRole: role,
    });
    return next;
  });

  await writeAdminEvent({
    agencyId,
    actorId: uid,
    actorRole: role,
    type: "CARD_TOPUP",
    description: `Top up card ${cardId} by RWF ${amountRwf}`,
    payload: {cardId, amountRwf, newBalance},
  });

  return {ok: true, cardId, newBalanceRwf: newBalance};
});

exports.setCardActive = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const uid = request.auth.uid;
  const {agencyId, role} = await getAgencyMembership(uid);
  assertRole(role, ["agency_admin", "agency_staff"]);

  const cardId = String(request.data?.cardId || "").trim();
  const active = request.data?.active === true;
  if (!cardId) {
    throw new HttpsError("invalid-argument", "cardId is required.");
  }

  const now = admin.firestore.Timestamp.now();
  const cardRef = db.collection("cards").doc(cardId);
  const cardSnap = await cardRef.get();
  if (!cardSnap.exists) {
    throw new HttpsError("not-found", "Card not found.");
  }
  const card = cardSnap.data() || {};
  const issuerAgencyId = String(card.issuerAgencyId || "");
  if (issuerAgencyId && issuerAgencyId !== agencyId) {
    throw new HttpsError("permission-denied", "Card belongs to another agency.");
  }

  await cardRef.set({
    active,
    updatedAt: now,
    statusUpdatedBy: uid,
    statusUpdatedRole: role,
  }, {merge: true});

  await writeAdminEvent({
    agencyId,
    actorId: uid,
    actorRole: role,
    type: active ? "CARD_REACTIVATED" : "CARD_CUT",
    description: `${active ? "Reactivated" : "Cut"} card ${cardId}`,
    payload: {cardId, active},
  });

  return {ok: true, cardId, active};
});

exports.requestCardStatusChange = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const uid = request.auth.uid;
  await assertUserIsActive(uid);

  const cardId = String(request.data?.cardId || "").trim();
  const active = request.data?.active === true;
  if (!cardId) {
    throw new HttpsError("invalid-argument", "cardId is required.");
  }

  const cardSnap = await db.collection("cards").doc(cardId).get();
  if (!cardSnap.exists) {
    throw new HttpsError("not-found", "Card not found.");
  }
  const card = cardSnap.data() || {};
  if (String(card.userId || "") !== uid) {
    throw new HttpsError("permission-denied", "Card does not belong to you.");
  }

  const now = admin.firestore.Timestamp.now();
  const userSnap = await db.collection("users").doc(uid).get();
  const user = userSnap.data() || {};

  const reqRef = await db.collection("card_status_requests").add({
    cardId,
    userId: uid,
    userEmail: String(user.email || request.auth.token.email || ""),
    userName: readableUserName(user),
    requestedActive: active,
    type: active ? "reactivate" : "cut",
    status: "pending",
    createdAt: now,
    updatedAt: now,
  });

  return {ok: true, requestId: reqRef.id, cardId, requestedActive: active};
});

exports.openAgencyByPassword = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const uid = request.auth.uid;
  await assertUserIsActive(uid);
  const requestedAgencyRef = String(request.data?.agencyId || "").trim();
  const password = String(request.data?.password || "").trim();
  if (!password) {
    throw new HttpsError("invalid-argument", "password is required.");
  }
  const {agencyId, role} = await getAgencyMembership(uid);

  if (requestedAgencyRef) {
    const requestedAgencyId = await resolveAgencyIdRef(requestedAgencyRef);
    if (requestedAgencyId !== agencyId) {
      throw new HttpsError(
        "permission-denied",
        "You can only open your assigned agency account.",
      );
    }
  }
  await assertAgencyIsActive(agencyId);

  const secretSnap = await db.collection("agency_secrets").doc(agencyId).get();
  if (!secretSnap.exists) {
    throw new HttpsError(
      "failed-precondition",
      "Agency password not set yet. Ask agency admin.",
    );
  }
  const secret = secretSnap.data() || {};
  const expectedHash = String(secret.passwordHash || "");
  if (!expectedHash || !verifyPassword(password, expectedHash)) {
    throw new HttpsError("permission-denied", "Invalid agency password.");
  }
  // Transparent upgrade of legacy SHA-256 hashes after first successful login.
  if (!expectedHash.startsWith("s2$")) {
    await db.collection("agency_secrets").doc(agencyId).set({
      passwordHash: hashPassword(password),
      updatedAt: admin.firestore.Timestamp.now(),
      updatedBy: uid,
    }, {merge: true});
  }

  return {ok: true, agencyId, role: String(role || "")};
});

exports.setAgencyAccessPassword = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const uid = request.auth.uid;
  const {agencyId, role} = await getAgencyMembership(uid);
  assertRole(role, ["agency_admin"]);

  const password = String(request.data?.password || "").trim();
  if (password.length < 4) {
    throw new HttpsError("invalid-argument", "Password must be at least 4 characters.");
  }

  const now = admin.firestore.Timestamp.now();
  await db.collection("agency_secrets").doc(agencyId).set({
    passwordHash: hashPassword(password),
    updatedAt: now,
    updatedBy: uid,
  }, {merge: true});

  await writeAdminEvent({
    agencyId,
    actorId: uid,
    actorRole: role,
    type: "AGENCY_PASSWORD_UPDATED",
    description: "Updated agency access password.",
    payload: {},
  });

  return {ok: true, agencyId};
});

exports.requestAgencyPasswordReset = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }

  const uid = request.auth.uid;
  const agencyId = String(request.data?.agencyId || "").trim();
  if (!agencyId) {
    throw new HttpsError("invalid-argument", "agencyId is required.");
  }
  const now = admin.firestore.Timestamp.now();
  const memberSnap = await db.collection("agency_members").doc(uid).get();
  if (!memberSnap.exists) {
    throw new HttpsError("permission-denied", "No agency membership found.");
  }
  const member = memberSnap.data() || {};
  if (member.active !== true || String(member.agencyId || "") !== agencyId) {
    throw new HttpsError("permission-denied", "You do not belong to this agency.");
  }

  const existing = await db.collection("agency_password_reset_requests")
    .where("agencyId", "==", agencyId)
    .where("requesterUid", "==", uid)
    .where("status", "==", "pending")
    .limit(1)
    .get();
  if (!existing.empty) {
    return {ok: true, alreadyPending: true, requestId: existing.docs[0].id};
  }

  const reqRef = await db.collection("agency_password_reset_requests").add({
    agencyId,
    requesterUid: uid,
    requesterEmail: String(request.auth.token.email || ""),
    requesterName: String(request.auth.token.name || ""),
    role: String(member.role || ""),
    status: "pending",
    createdAt: now,
    updatedAt: now,
    resolvedAt: null,
    resolvedBy: null,
  });

  await db.collection("mail").add({
    to: ["nelsonjembe99@gmail.com"],
    message: {
      subject: `SpotLight: Agency password reset request (${agencyId})`,
      text: [
        `Request ID: ${reqRef.id}`,
        `Agency ID: ${agencyId}`,
        `Requester UID: ${uid}`,
        `Requester email: ${String(request.auth.token.email || "")}`,
        `Requester role: ${String(member.role || "")}`,
        "",
        "Action: Super admin should verify and ask agency admin to set a new password.",
      ].join("\n"),
    },
  });

  return {ok: true, requestId: reqRef.id, alreadyPending: false};
});

exports.resolveAgencyPasswordReset = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  assertSuperAdmin(request);

  const requestId = String(request.data?.requestId || "").trim();
  const status = String(request.data?.status || "resolved").trim();
  if (!requestId || !["resolved", "rejected"].includes(status)) {
    throw new HttpsError("invalid-argument", "Invalid requestId/status.");
  }

  const uid = request.auth.uid;
  const now = admin.firestore.Timestamp.now();
  const ref = db.collection("agency_password_reset_requests").doc(requestId);
  const snap = await ref.get();
  if (!snap.exists) {
    throw new HttpsError("not-found", "Reset request not found.");
  }
  const data = snap.data() || {};
  if (String(data.status || "") !== "pending") {
    return {ok: true, alreadyHandled: true};
  }

  await ref.update({
    status,
    resolvedAt: now,
    resolvedBy: uid,
    updatedAt: now,
  });

  return {ok: true, requestId, status};
});

exports.getSystemCounts = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  assertSuperAdmin(request);

  const [
    usersSnap,
    pagesSnap,
    agenciesSnap,
    activeUsersSnap,
    activePagesSnap,
    activeAgenciesSnap,
    allFinance,
    spotlightBank,
  ] = await Promise.all([
    db.collection("users").count().get(),
    db.collection("businesses").count().get(),
    db.collection("agencies").count().get(),
    db.collection("users").where("isActive", "!=", false).count().get(),
    db.collection("businesses").where("isActive", "==", true).count().get(),
    db.collection("agencies").where("active", "==", true).count().get(),
    aggregatePaidBookings(),
    getSpotlightBankAccount(),
  ]);

  return {
    ok: true,
    totals: {
      users: usersSnap.data().count || 0,
      pages: pagesSnap.data().count || 0,
      agencies: agenciesSnap.data().count || 0,
    },
    active: {
      users: activeUsersSnap.data().count || 0,
      pages: activePagesSnap.data().count || 0,
      agencies: activeAgenciesSnap.data().count || 0,
    },
    money: allFinance,
    spotlightRevenueSharePercent: SPOTLIGHT_REVENUE_SHARE_PERCENT,
    spotlightBank: spotlightBank,
  };
});

exports.getSystemFinanceBreakdown = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  assertSuperAdmin(request);

  const [totals, grouped, agenciesSnap, spotlightBank] = await Promise.all([
    aggregatePaidBookings(),
    aggregatePaidBookingsByAgency(),
    db.collection("agencies").limit(500).get(),
    getSpotlightBankAccount(),
  ]);

  const agenciesMap = new Map();
  for (const d of agenciesSnap.docs) agenciesMap.set(d.id, d.data() || {});

  const perAgency = [];
  for (const [agencyId, money] of grouped.entries()) {
    const agency = agenciesMap.get(agencyId) || {};
    perAgency.push({
      agencyId,
      agencyName: String(agency.name || agencyId),
      agencyBank: {
        accountName: String(agency.bankAccountName || ""),
        bankName: String(agency.bankName || ""),
        accountNumber: String(agency.bankAccountNumber || ""),
      },
      ...money,
    });
  }
  perAgency.sort((a, b) => Number(b.totalFareRwf || 0) - Number(a.totalFareRwf || 0));

  return {
    ok: true,
    totals,
    perAgency,
    spotlightRevenueSharePercent: SPOTLIGHT_REVENUE_SHARE_PERCENT,
    spotlightBank,
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
  if (!entityType || !entityId || !["user", "page", "agency"].includes(entityType)) {
    throw new HttpsError("invalid-argument", "Invalid entityType/entityId.");
  }

  const now = admin.firestore.Timestamp.now();
  if (entityType === "user") {
    await db.collection("users").doc(entityId).set({
      isActive: active,
      updatedAt: now,
    }, {merge: true});
  } else if (entityType === "page") {
    await db.collection("businesses").doc(entityId).set({
      isActive: active,
      updatedAt: now,
    }, {merge: true});
  } else {
    await db.collection("agencies").doc(entityId).set({
      active,
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
  if (!entityType || !entityId || !["user", "page", "agency"].includes(entityType)) {
    throw new HttpsError("invalid-argument", "Invalid entityType/entityId.");
  }

  const collection = entityType === "user" ? "users" : (entityType === "page" ? "businesses" : "agencies");
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

/**
 * Real agency application from app users.
 * This is reviewed by super admin before access is provisioned.
 */
exports.submitAgencyApplication = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }

  const uid = request.auth.uid;
  await assertUserIsActive(uid);
  const email = String(request.auth.token.email || "").toLowerCase();
  const now = admin.firestore.Timestamp.now();
  const data = request.data || {};

  const agencyName = String(data.agencyName || "").trim();
  const fullName = String(data.fullName || "").trim();
  const phone = String(data.phone || "").trim();
  const whatsapp = String(data.whatsapp || "").trim();
  const spotlightUsername = String(data.spotlightUsername || "").trim();
  const agencyPassword = String(data.agencyPassword || "").trim();
  const fleetSize = Number(data.fleetSize || 0);
  const notes = String(data.notes || "").trim();

  if (!agencyName || !fullName || !email || !phone || !spotlightUsername) {
    throw new HttpsError("invalid-argument", "Missing required fields.");
  }
  if (agencyPassword.length < 4) {
    throw new HttpsError(
      "invalid-argument",
      "Agency entry password must be at least 4 characters.",
    );
  }
  if (!Number.isFinite(fleetSize) || fleetSize <= 0) {
    throw new HttpsError("invalid-argument", "Fleet size must be greater than 0.");
  }

  const existingSnap = await db.collection("agency_applications")
    .where("ownerUid", "==", uid)
    .where("status", "in", ["pending", "under_review"])
    .limit(1)
    .get();
  if (!existingSnap.empty) {
    throw new HttpsError("already-exists", "You already have a pending application.");
  }

  const ref = await db.collection("agency_applications").add({
    ownerUid: uid,
    ownerEmail: email,
    agencyName,
    agencyNameLower: normalizeAgencyName(agencyName),
    fleetSize,
    contact: {
      fullName,
      phone,
      whatsapp,
      spotlightUsername,
    },
    notes,
    requestedPasswordHash: hashPassword(agencyPassword),
    status: "pending",
    submittedAt: now,
    updatedAt: now,
    reviewedAt: null,
    reviewedBy: null,
  });

  // Works if Trigger Email extension is enabled.
  await db.collection("mail").add({
    to: ["nelsonjembe99@gmail.com"],
    message: {
      subject: `SpotLight Agency Application: ${agencyName}`,
      text: [
        `Application ID: ${ref.id}`,
        `Agency: ${agencyName}`,
        `Owner: ${fullName}`,
        `Email: ${email}`,
        `Phone: ${phone}`,
        `WhatsApp: ${whatsapp}`,
        `SpotLight username: ${spotlightUsername}`,
        `Fleet size: ${fleetSize}`,
        `Notes: ${notes || "N/A"}`,
        "Agency entry password was provided by applicant.",
      ].join("\n"),
    },
  });

  return {ok: true, applicationId: ref.id, status: "pending"};
});

/**
 * Super admin approves application and provisions agency + first admin access.
 */
exports.approveAgencyApplication = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  assertSuperAdmin(request);

  const applicationId = String(request.data?.applicationId || "").trim();
  if (!applicationId) {
    throw new HttpsError("invalid-argument", "applicationId is required.");
  }

  const uid = request.auth.uid;
  const now = admin.firestore.Timestamp.now();
  const appRef = db.collection("agency_applications").doc(applicationId);

  const result = await db.runTransaction(async (tx) => {
    const appSnap = await tx.get(appRef);
    if (!appSnap.exists) {
      throw new HttpsError("not-found", "Application not found.");
    }
    const app = appSnap.data() || {};
    const status = String(app.status || "");
    if (status !== "pending" && status !== "under_review") {
      throw new HttpsError("failed-precondition", "Application is not approvable.");
    }

    const ownerUid = String(app.ownerUid || "");
    const agencyName = String(app.agencyName || "").trim();
    const contact = app.contact || {};
    const adminPhone = String(contact.phone || "").trim();
    const adminName = String(contact.fullName || "").trim();
    if (!ownerUid || !agencyName) {
      throw new HttpsError("failed-precondition", "Application data is incomplete.");
    }

    const agencyId = String(request.data?.agencyId || "").trim() || `agency_${applicationId}`;
    const agencyRef = db.collection("agencies").doc(agencyId);
    const memberRef = db.collection("agency_members").doc(ownerUid);

    tx.set(agencyRef, {
      name: agencyName,
      nameLower: normalizeAgencyName(agencyName),
      code: String(request.data?.agencyCode || "").trim().toUpperCase(),
      active: true,
      ownerUid,
      adminPhone,
      adminName,
      approvedFromApplicationId: applicationId,
      createdAt: now,
      updatedAt: now,
    }, {merge: true});

    tx.set(memberRef, {
      agencyId,
      role: "agency_admin",
      active: true,
      source: "application_approval",
      updatedAt: now,
      createdAt: now,
    }, {merge: true});

    const requestedPasswordHash = String(app.requestedPasswordHash || "");
    if (requestedPasswordHash) {
      tx.set(db.collection("agency_secrets").doc(agencyId), {
        passwordHash: requestedPasswordHash,
        updatedAt: now,
        updatedBy: ownerUid,
      }, {merge: true});
    }

    tx.update(appRef, {
      status: "approved",
      reviewedAt: now,
      reviewedBy: uid,
      updatedAt: now,
      provisionedAgencyId: agencyId,
    });

    return {agencyId, ownerUid, agencyName};
  });

  await writeAdminEvent({
    agencyId: result.agencyId,
    actorId: uid,
    actorRole: "super_admin",
    type: "AGENCY_APPROVED",
    description: `Approved agency "${result.agencyName}" from application ${applicationId}`,
    payload: {applicationId, ownerUid: result.ownerUid},
  });

  return {ok: true, ...result};
});

exports.rejectAgencyApplication = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  assertSuperAdmin(request);

  const applicationId = String(request.data?.applicationId || "").trim();
  const reason = String(request.data?.reason || "").trim();
  if (!applicationId) {
    throw new HttpsError("invalid-argument", "applicationId is required.");
  }

  const uid = request.auth.uid;
  const now = admin.firestore.Timestamp.now();
  const ref = db.collection("agency_applications").doc(applicationId);
  const snap = await ref.get();
  if (!snap.exists) {
    throw new HttpsError("not-found", "Application not found.");
  }
  const app = snap.data() || {};
  const status = String(app.status || "");
  if (status !== "pending" && status !== "under_review") {
    throw new HttpsError("failed-precondition", "Application is not rejectable.");
  }

  await ref.update({
    status: "rejected",
    rejectReason: reason || "Not approved at this time.",
    reviewedAt: now,
    reviewedBy: uid,
    updatedAt: now,
  });

  return {ok: true, applicationId, status: "rejected"};
});

exports.assignAgencyStaffRole = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const uid = request.auth.uid;
  const {agencyId, role} = await getAgencyMembership(uid);
  assertRole(role, ["agency_admin"]);

  const targetUid = String(request.data?.targetUid || "").trim();
  const targetEmail = String(request.data?.targetEmail || "").trim().toLowerCase();
  let resolvedUid = targetUid;

  if (!resolvedUid && targetEmail) {
    let userSnap = await db.collection("users")
      .where("emailLower", "==", targetEmail)
      .limit(1)
      .get();
    if (userSnap.empty) {
      userSnap = await db.collection("users")
        .where("email", "==", targetEmail)
        .limit(1)
        .get();
    }
    if (!userSnap.empty) {
      resolvedUid = userSnap.docs[0].id;
    }
  }

  if (!resolvedUid) {
    throw new HttpsError("invalid-argument", "targetUid or targetEmail is required.");
  }
  if (resolvedUid === uid) {
    throw new HttpsError("failed-precondition", "You already have admin access.");
  }

  const userRef = db.collection("users").doc(resolvedUid);
  const memberRef = db.collection("agency_members").doc(resolvedUid);
  const now = admin.firestore.Timestamp.now();

  await db.runTransaction(async (tx) => {
    const userSnap = await tx.get(userRef);
    if (!userSnap.exists) {
      throw new HttpsError("not-found", "User not found.");
    }

    tx.set(memberRef, {
      agencyId,
      role: "agency_staff",
      active: true,
      assignedBy: uid,
      updatedAt: now,
      createdAt: now,
    }, {merge: true});
  });

  const targetUserSnap = await db.collection("users").doc(resolvedUid).get();
  const targetUserName = readableUserName(targetUserSnap.data() || {}) || resolvedUid;

  await writeAdminEvent({
    agencyId,
    actorId: uid,
    actorRole: "agency_admin",
    type: "STAFF_ASSIGNED",
    description: `Assigned agency_staff to ${targetUserName}`,
    payload: {targetUid: resolvedUid, targetUserName},
  });

  return {ok: true, agencyId, targetUid: resolvedUid, role: "agency_staff"};
});

exports.getAgencyFinancialReport = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const uid = request.auth.uid;
  const superAdmin = isSuperAdminAuth(request);

  let agencyId = String(request.data?.agencyId || "").trim();
  let role = "";

  if (!superAdmin) {
    const member = await getAgencyMembership(uid);
    agencyId = member.agencyId;
    role = member.role;
    assertRole(role, ["agency_admin"]);
  }

  if (!agencyId) {
    throw new HttpsError("invalid-argument", "agencyId is required.");
  }

  const [agencySnap, split, spotlightBank] = await Promise.all([
    db.collection("agencies").doc(agencyId).get(),
    aggregatePaidBookings({agencyId}),
    getSpotlightBankAccount(),
  ]);
  const agency = agencySnap.data() || {};

  return {
    ok: true,
    agencyId,
    role: superAdmin ? "super_admin" : role,
    money: split,
    agencyBank: {
      accountName: String(agency.bankAccountName || ""),
      bankName: String(agency.bankName || ""),
      accountNumber: String(agency.bankAccountNumber || ""),
    },
    spotlightBank: spotlightBank,
    spotlightRevenueSharePercent: SPOTLIGHT_REVENUE_SHARE_PERCENT,
  };
});

exports.updateBankAccounts = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }

  const scope = String(request.data?.scope || "").trim().toLowerCase();
  const accountName = String(request.data?.accountName || "").trim();
  const bankName = String(request.data?.bankName || "").trim();
  const accountNumber = String(request.data?.accountNumber || "").trim();
  if (!scope || !accountName || !bankName || !accountNumber) {
    throw new HttpsError("invalid-argument", "scope/accountName/bankName/accountNumber are required.");
  }

  const now = admin.firestore.Timestamp.now();
  const uid = request.auth.uid;

  if (scope === "spotlight") {
    assertSuperAdmin(request);
    await db.collection("system_settings").doc("finance").set({
      spotlightBank: {accountName, bankName, accountNumber},
      updatedAt: now,
      updatedBy: uid,
    }, {merge: true});
    return {ok: true, scope: "spotlight"};
  }

  if (scope !== "agency") {
    throw new HttpsError("invalid-argument", "scope must be spotlight or agency.");
  }

  let targetAgencyId = String(request.data?.agencyId || "").trim();
  const isSuper = isSuperAdminAuth(request);
  let actorRole = "agency_admin";
  if (!isSuper) {
    const member = await getAgencyMembership(uid);
    assertRole(member.role, ["agency_admin"]);
    targetAgencyId = member.agencyId;
    actorRole = member.role;
  } else if (!targetAgencyId) {
    throw new HttpsError("invalid-argument", "agencyId is required for super admin.");
  }

  await db.collection("agencies").doc(targetAgencyId).set({
    bankAccountName: accountName,
    bankName,
    bankAccountNumber: accountNumber,
    updatedAt: now,
  }, {merge: true});

  await writeAdminEvent({
    agencyId: targetAgencyId,
    actorId: uid,
    actorRole: isSuper ? "super_admin" : actorRole,
    type: "BANK_ACCOUNT_UPDATED",
    description: "Updated agency bank account details.",
    payload: {},
  });

  return {ok: true, scope: "agency", agencyId: targetAgencyId};
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
    default:
      return "SpotLight";
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
      return preview || "You have a new SpotLight update.";
  }
}
