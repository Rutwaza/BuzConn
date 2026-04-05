const admin = require("firebase-admin");
const crypto = require("crypto");
const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const {onCall, onRequest, HttpsError} = require("firebase-functions/v2/https");
const functionsV1 = require("firebase-functions/v1");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const {onValueCreated} = require("firebase-functions/v2/database");
const logger = require("firebase-functions/logger");

admin.initializeApp();
const db = admin.firestore();

const BOOKING_STATUS = {
  BOOKED: "booked",
  PAID: "paid",
  EXPIRED: "expired",
  CANCELLED: "cancelled",
};

const SUPER_ADMIN_EMAILS = new Set([
  "nelsonjembe99@gmail.com",
]);

const DEMO_AGENCY = {
  id: "demo_transport_ltd",
  name: "Example Transport Ltd",
  code: "ET",
  routeId: "example_nyabugogo_kimironko",
  // Match your current RTDB sample device id so demo appears live immediately.
  busId: "syndicate4",
  plateNumber: "RAD001E",
};

function hashPassword(raw) {
  return crypto.createHash("sha256").update(String(raw)).digest("hex");
}

function normalizeAgencyName(name) {
  return String(name || "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, " ");
}

function readableUserName(data) {
  return String(data?.displayName || data?.name || data?.username || "").trim();
}

exports.sendNotificationPush = onDocumentCreated(
  "notifications/{notificationId}",
  async (event) => {
    const notification = event.data?.data();
    if (!notification) return;

    const toUserId = notification.toUserId;
    if (!toUserId) return;

    const userSnap = await db.collection("users").doc(toUserId).get();
    if (!userSnap.exists) return;

    const userData = userSnap.data() || {};
    const tokens = Array.isArray(userData.fcmTokens)
      ? userData.fcmTokens.filter(Boolean)
      : [];

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
          channelId: type === "message" ? "spotlight_chat" : "spotlight_activity",
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
      await db.collection("users").doc(toUserId).set(
        {
          fcmTokens: admin.firestore.FieldValue.arrayRemove(...invalidTokens),
        },
        {merge: true},
      );
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

exports.backfillDiscoveredBuses = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }

  const email = String(request.auth.token.email || "").toLowerCase();
  const isSuper = SUPER_ADMIN_EMAILS.has(email);
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

/**
 * Shared booking handler for v2 callable + v1 fallback callable.
 * request shape: { auth?: { uid?: string }, data?: {...} }
 */
async function handleBookSeat(request) {
  // Primary path: callable auth context.
  // Fallback path: some Android setups intermittently miss callable auth headers;
  // allow explicit uid for development flow.
  const uid = String(request.auth?.uid || request.data?.uid || "").trim();
  if (!uid) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
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
    if (String(bus.routeId || "") !== routeId) {
      throw new HttpsError("failed-precondition", "Bus not assigned to route.");
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

    if (availableSeats <= 0) {
      throw new HttpsError("failed-precondition", "No seats available.");
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
      .limit(1);
    const seatSnap = await tx.get(seatQuery);
    if (!seatSnap.empty) {
      throw new HttpsError("already-exists", "Seat already occupied/booked.");
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
  assertRole(role, ["agency_admin", "agency_staff", "agency_reader"]);

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

async function getAgencyMembership(uid) {
  const snap = await db.collection("agency_members").doc(uid).get();
  if (!snap.exists) {
    throw new HttpsError("permission-denied", "No agency membership found.");
  }
  const d = snap.data() || {};
  if (d.active !== true) {
    throw new HttpsError("permission-denied", "Agency membership is inactive.");
  }
  const agencyId = String(d.agencyId || "");
  const role = String(d.role || "").trim().toLowerCase();
  if (!agencyId || !role) {
    throw new HttpsError("permission-denied", "Invalid agency membership.");
  }
  return {agencyId, role};
}

function assertSuperAdmin(request) {
  const email = String(request.auth?.token?.email || "").toLowerCase();
  if (!SUPER_ADMIN_EMAILS.has(email)) {
    throw new HttpsError("permission-denied", "Super admin only.");
  }
}

function isSuperAdminAuth(request) {
  const email = String(request.auth?.token?.email || "").toLowerCase();
  return SUPER_ADMIN_EMAILS.has(email);
}

function assertRole(role, allowed) {
  const normalizedRole = String(role || "").trim().toLowerCase();
  if (!allowed.includes(normalizedRole)) {
    throw new HttpsError("permission-denied", "Insufficient role permissions.");
  }
}

async function writeAdminEvent({agencyId, actorId, actorRole, type, description, payload}) {
  await db.collection("admin_events").add({
    agencyId,
    actorId,
    actorRole,
    type,
    description,
    payload: payload || {},
    createdAt: admin.firestore.Timestamp.now(),
  });
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

  const now = admin.firestore.Timestamp.now();
  const ref = routeId
    ? db.collection("routes").doc(routeId)
    : db.collection("routes").doc();

  if (routeId) {
    const existing = await ref.get();
    if (existing.exists) {
      const d = existing.data() || {};
      if (String(d.agencyId || "") !== agencyId) {
        throw new HttpsError("permission-denied", "Route belongs to another agency.");
      }
    }
  }

  await ref.set({
    agencyId: "",
    global: true,
    directionKey,
    origin,
    destination,
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

exports.assignRouteToBus = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const uid = request.auth.uid;
  const {agencyId, role} = await getAgencyMembership(uid);
  assertRole(role, ["agency_admin", "agency_staff", "agency_reader"]);

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

    tx.update(busRef, {
      routeId,
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

exports.createOrUpdateBus = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const uid = request.auth.uid;
  const {agencyId, role} = await getAgencyMembership(uid);
  assertRole(role, ["agency_admin", "agency_staff", "agency_reader"]);

  const busId = String(request.data?.busId || "").trim();
  const agencyName = String(request.data?.agencyName || "").trim();
  const plateNumber = String(request.data?.plateNumber || "").trim();
  const routeId = String(request.data?.routeId || "").trim();
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

  if (routeId) {
    const routeSnap = await db.collection("routes").doc(routeId).get();
    if (!routeSnap.exists) {
      throw new HttpsError("not-found", "Route not found.");
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
  await ref.set({
    agencyId,
    agencyName: agencyName || "Agency Bus",
    plateNumber,
    routeId,
    capacity,
    availableSeats,
    active,
    ...(deviceSecret ? {deviceSecret} : {}),
    createdAt: now,
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
  assertRole(role, ["agency_admin", "agency_staff", "agency_reader"]);

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

/**
 * Demo onboarding: user enters known demo password to get agency admin access.
 */
exports.enterDemoAgency = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }

  const password = String(request.data?.password || "").trim();
  const expected = String(process.env.DEMO_AGENCY_PASSWORD || "demopassword");
  if (!password || password !== expected) {
    throw new HttpsError("permission-denied", "Invalid demo password.");
  }

  const uid = request.auth.uid;
  const now = admin.firestore.Timestamp.now();

  const agencyRef = db.collection("agencies").doc(DEMO_AGENCY.id);
  const routeRef = db.collection("routes").doc(DEMO_AGENCY.routeId);
  const busRef = db.collection("buses").doc(DEMO_AGENCY.busId);
  const memberRef = db.collection("agency_members").doc(uid);

  const batch = db.batch();
  batch.set(agencyRef, {
    name: DEMO_AGENCY.name,
    nameLower: normalizeAgencyName(DEMO_AGENCY.name),
    code: DEMO_AGENCY.code,
    active: true,
    createdAt: now,
    updatedAt: now,
  }, {merge: true});
  batch.set(routeRef, {
    agencyId: DEMO_AGENCY.id,
    origin: "Nyabugogo",
    destination: "Kimironko",
    fareRwf: 500,
    active: true,
    createdAt: now,
    updatedAt: now,
  }, {merge: true});
  batch.set(busRef, {
    agencyId: DEMO_AGENCY.id,
    agencyName: DEMO_AGENCY.name,
    plateNumber: DEMO_AGENCY.plateNumber,
    routeId: DEMO_AGENCY.routeId,
    capacity: 30,
    availableSeats: 28,
    active: true,
    deviceSecret: "CHANGE_ME_DEVICE_SECRET",
    createdAt: now,
    updatedAt: now,
  }, {merge: true});
  batch.set(memberRef, {
    agencyId: DEMO_AGENCY.id,
    role: "agency_admin",
    active: true,
    source: "demo_password",
    updatedAt: now,
    createdAt: now,
  }, {merge: true});
  await batch.commit();

  await writeAdminEvent({
    agencyId: DEMO_AGENCY.id,
    actorId: uid,
    actorRole: "agency_admin",
    type: "DEMO_ACCESS_GRANTED",
    description: "Entered demo agency using password.",
    payload: {uid},
  });

  return {
    ok: true,
    agencyId: DEMO_AGENCY.id,
    role: "agency_admin",
  };
});

exports.openAgencyByPassword = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const uid = request.auth.uid;
  const agencyId = String(request.data?.agencyId || "").trim();
  const password = String(request.data?.password || "").trim();
  if (!agencyId || !password) {
    throw new HttpsError("invalid-argument", "agencyId and password are required.");
  }

  if (agencyId == DEMO_AGENCY.id) {
    const expected = String(process.env.DEMO_AGENCY_PASSWORD || "demopassword");
    if (password !== expected) {
      throw new HttpsError("permission-denied", "Invalid demo password.");
    }
    const now = admin.firestore.Timestamp.now();
    await db.collection("agencies").doc(DEMO_AGENCY.id).set({
      name: DEMO_AGENCY.name,
      nameLower: normalizeAgencyName(DEMO_AGENCY.name),
      code: DEMO_AGENCY.code,
      active: true,
      updatedAt: now,
      createdAt: now,
    }, {merge: true});
    await db.collection("agency_members").doc(uid).set({
      agencyId: DEMO_AGENCY.id,
      role: "agency_admin",
      active: true,
      source: "demo_password",
      updatedAt: now,
      createdAt: now,
    }, {merge: true});
    return {ok: true, agencyId: DEMO_AGENCY.id, role: "agency_admin"};
  }

  const memberSnap = await db.collection("agency_members").doc(uid).get();
  if (!memberSnap.exists) {
    throw new HttpsError("permission-denied", "No agency membership.");
  }
  const member = memberSnap.data() || {};
  if (member.active !== true || String(member.agencyId || "") !== agencyId) {
    throw new HttpsError("permission-denied", "You do not belong to this agency.");
  }

  const secretSnap = await db.collection("agency_secrets").doc(agencyId).get();
  if (!secretSnap.exists) {
    throw new HttpsError(
      "failed-precondition",
      "Agency password not set yet. Ask agency admin.",
    );
  }
  const secret = secretSnap.data() || {};
  const expectedHash = String(secret.passwordHash || "");
  if (!expectedHash || hashPassword(password) !== expectedHash) {
    throw new HttpsError("permission-denied", "Invalid agency password.");
  }

  return {ok: true, agencyId, role: String(member.role || "")};
});

exports.setAgencyAccessPassword = onCall({region: "us-central1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const uid = request.auth.uid;
  const {agencyId, role} = await getAgencyMembership(uid);
  assertRole(role, ["agency_admin", "agency_staff", "agency_reader"]);

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
  if (agencyId === DEMO_AGENCY.id) {
    throw new HttpsError("failed-precondition", "Demo agency password is fixed.");
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
  ] = await Promise.all([
    db.collection("users").count().get(),
    db.collection("businesses").count().get(),
    db.collection("agencies").count().get(),
    db.collection("users").where("isActive", "!=", false).count().get(),
    db.collection("businesses").where("isActive", "==", true).count().get(),
    db.collection("agencies").where("active", "==", true).count().get(),
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

function buildTitle(type, fromName) {
  switch (type) {
    case "message":
      return fromName;
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
