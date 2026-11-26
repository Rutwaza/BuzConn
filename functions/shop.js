/**
 * Shop: business catalogs and orders.
 *
 * Products live in `businesses/{businessId}/products/{productId}` and are
 * written by the business owner (rules check that).
 *
 * Orders live in `orders/{orderId}`. The app cannot create them directly:
 * it calls `createOrder`, and the server reads the real prices, so a buyer
 * cannot change a price. Status flow for MoMo USSD (manual):
 *
 *   pending_payment --buyer "I paid"--> paid_claimed --shop "Received"--> confirmed
 *        |                                   |                               |
 *        +--buyer "Cancel"--> cancelled      +--shop "Not received"-->     shop "Ready"
 *                                               not_received                 v
 *                                               (buyer can pay again)      ready --shop "Delivered"--> delivered
 *
 * Double orders: the app sends a `requestId` made once per checkout. The
 * same requestId always gives the same order (a second tap, a retry after
 * a bad connection...). An identical unpaid order made in the last few
 * minutes is also returned instead of making a new one.
 *
 * The rules (firestore.rules -> orders) allow exactly these moves.
 * `onOrderWritten` sends the notifications for each move.
 */
const admin = require("firebase-admin");
const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {onDocumentWritten} = require("firebase-functions/v2/firestore");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const crypto = require("crypto");
const {getProvider} = require("./payments");

const REGION = "us-central1";
const DEFAULT_PROVIDER = "momo_ussd";
const MAX_ITEMS = 20;
const MAX_QTY = 99;
const SAME_ORDER_WINDOW_MS = 5 * 60 * 1000;

/** "a1:2,b7:1" - the same cart always gives the same text. */
function cartKey(items) {
  return items.map((i) => `${i.productId}:${i.qty}`).sort().join(",");
}

const db = () => admin.firestore();
const FieldValue = admin.firestore.FieldValue;

function rwf(n) {
  return `${Number(n || 0).toLocaleString("en-US")} RWF`;
}

async function profile(uid) {
  const d = (await db().collection("users").doc(uid).get()).data() || {};
  return {
    name: String(d.name || d.displayName || "Someone"),
    imageUrl: String(d.imageUrl || "").trim() || null,
  };
}

exports.createOrder = onCall({region: REGION}, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");
  const businessId = String(request.data?.businessId || "");
  const wanted = Array.isArray(request.data?.items) ? request.data.items : [];
  if (!businessId || wanted.length === 0 || wanted.length > MAX_ITEMS) {
    throw new HttpsError("invalid-argument", "Choose between 1 and 20 products.");
  }

  const bizSnap = await db().collection("businesses").doc(businessId).get();
  const biz = bizSnap.data();
  if (!biz || biz.isActive === false) {
    throw new HttpsError("not-found", "This shop is not available.");
  }
  if (biz.ownerId === uid) {
    throw new HttpsError("failed-precondition", "You cannot buy from your own shop.");
  }
  const momoCode = String(biz.momoCode || "").trim();
  if (!/^\d{4,10}$/.test(momoCode)) {
    throw new HttpsError("failed-precondition", "This shop has not set a MoMo Pay code yet.");
  }

  // Real prices from the catalog, never from the phone.
  const items = [];
  let total = 0;
  for (const w of wanted) {
    const productId = String(w?.productId || "");
    const qty = Math.floor(Number(w?.qty));
    if (!productId || !(qty >= 1 && qty <= MAX_QTY)) {
      throw new HttpsError("invalid-argument", "Bad product or quantity.");
    }
    const p = (await bizSnap.ref.collection("products").doc(productId).get()).data();
    if (!p || p.inStock === false) {
      throw new HttpsError("failed-precondition", `"${p?.name || "A product"}" is not available.`);
    }
    const price = Math.round(Number(p.price));
    items.push({productId, name: String(p.name || ""), price, qty, imageUrl: p.imageUrl || null});
    total += price * qty;
  }

  // Same checkout tapped twice (or retried): give back the first order.
  const requestId = String(request.data?.requestId || "");
  const ref = /^[A-Za-z0-9_-]{8,64}$/.test(requestId) ?
    db().collection("orders").doc(
      crypto.createHash("sha256").update(`${uid}:${requestId}`).digest("hex").slice(0, 24)) :
    db().collection("orders").doc();
  const existing = await ref.get();
  if (existing.exists) {
    const e = existing.data();
    if (e.buyerId !== uid) throw new HttpsError("already-exists", "Try again.");
    return {orderId: ref.id, total: e.total, payment: e.payment, momoName: e.momoName, reused: true};
  }
  // The same cart, still unpaid, a few minutes ago: reuse it too.
  const key = cartKey(items);
  const recent = await db().collection("orders")
    .where("buyerId", "==", uid)
    .where("businessId", "==", businessId)
    .where("status", "==", "pending_payment")
    .limit(10).get();
  const twin = recent.docs.find((d) => {
    const o = d.data();
    const at = o.createdAt?.toMillis?.() || 0;
    return o.cartKey === key && Date.now() - at < SAME_ORDER_WINDOW_MS;
  });
  if (twin) {
    const t = twin.data();
    return {orderId: twin.id, total: t.total, payment: t.payment, momoName: t.momoName, reused: true};
  }

  const provider = getProvider(DEFAULT_PROVIDER);
  const order = {
    id: ref.id,
    businessId,
    businessName: String(biz.name || "Shop"),
    businessOwnerId: String(biz.ownerId),
    buyerId: uid,
    items,
    total,
    currency: "RWF",
    provider: provider.id,
    momoCode,
    momoName: String(biz.momoName || "").trim() || null,
    status: "pending_payment",
    cartKey: key,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  };
  const payment = await provider.startPayment({...order});
  try {
    // create() fails if a parallel tap made it first: then return that one.
    await ref.create({...order, payment});
  } catch (e) {
    const made = (await ref.get()).data();
    if (made && made.buyerId === uid) {
      return {orderId: ref.id, total: made.total, payment: made.payment, momoName: made.momoName, reused: true};
    }
    throw e;
  }
  return {orderId: ref.id, total, payment, momoName: order.momoName};
});

const MESSAGES = {
  // status: [who is told, text]
  pending_payment: ["owner", (o, who) => `${who} ordered ${o.items.length} item(s) · ${rwf(o.total)}`],
  paid_claimed: ["owner", (o, who) => `${who} says they paid ${rwf(o.total)} by MoMo. Check your MoMo messages, then confirm.`],
  cancelled: ["owner", (o, who) => `${who} cancelled an order of ${rwf(o.total)}`],
  confirmed: ["buyer", (o) => `${o.businessName} confirmed your payment of ${rwf(o.total)} ✓`],
  not_received: ["buyer", (o) => `${o.businessName} has not received your ${rwf(o.total)} yet. Check and try again.`],
  ready: ["buyer", (o) => `Your order from ${o.businessName} is ready 📦`],
  delivered: ["buyer", (o) => `${o.businessName} marked your order as delivered ✓`],
};

exports.onOrderWritten = onDocumentWritten(
  {region: REGION, document: "orders/{orderId}"},
  async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    if (!after || before?.status === after.status) return;
    // First time an order is confirmed: count the sales for "Popular".
    if (after.status === "confirmed" && !after.soldCounted) {
      const batch = db().batch();
      for (const item of after.items || []) {
        if (!item.productId) continue;
        batch.set(db().collection("businesses").doc(after.businessId)
          .collection("products").doc(item.productId),
        {soldCount: FieldValue.increment(Number(item.qty) || 1)}, {merge: true});
      }
      batch.update(event.data.after.ref, {soldCounted: true});
      await batch.commit().catch((e) => console.warn("soldCount", e.message));
    }
    const msg = MESSAGES[after.status];
    if (!msg) return;
    const [to, text] = msg;
    const toUserId = to === "owner" ? after.businessOwnerId : after.buyerId;
    const fromUserId = to === "owner" ? after.buyerId : after.businessOwnerId;
    const buyer = await profile(after.buyerId);
    const from = to === "owner" ? buyer : {
      name: after.businessName,
      imageUrl: ((await db().collection("businesses").doc(after.businessId).get()).data() || {}).imageUrl || null,
    };
    await db().collection("notifications").add({
      toUserId,
      fromUserId,
      fromUserName: from.name,
      fromUserImageUrl: from.imageUrl,
      type: "order",
      orderId: event.params.orderId,
      preview: text(after, buyer.name),
      readAt: null,
      hidden: false,
      createdAt: FieldValue.serverTimestamp(),
    });
  },
);

// ------------------------------------------------- shop index & reviews --

/** businesses/{id}.productCount: lets the app show "Shop" on posts. */
async function recountProducts(businessId) {
  const biz = db().collection("businesses").doc(businessId);
  const snap = await biz.collection("products").where("inStock", "==", true).count().get();
  const count = snap.data().count;
  await biz.set({productCount: count}, {merge: true}).catch(() => {});
  return count;
}

exports.onProductWritten = onDocumentWritten(
  {region: REGION, document: "businesses/{businessId}/products/{productId}"},
  async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    // soldCount bumps don't change the count.
    if (before && after && before.inStock === after.inStock) return;
    await recountProducts(event.params.businessId);
  },
);

/** One review per person: businesses/{id}/reviews/{uid}. Keeps the average. */
exports.onReviewWritten = onDocumentWritten(
  {region: REGION, document: "businesses/{businessId}/reviews/{uid}"},
  async (event) => {
    const biz = db().collection("businesses").doc(event.params.businessId);
    const agg = await biz.collection("reviews").aggregate({
      count: admin.firestore.AggregateField.count(),
      avg: admin.firestore.AggregateField.average("rating"),
    }).get();
    const {count, avg} = agg.data();
    await biz.set({
      ratingCount: count,
      ratingAvg: count ? Math.round(Number(avg) * 10) / 10 : 0,
    }, {merge: true});
    // Tell the owner about a new review.
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    if (!before && after) {
      const owner = (await biz.get()).data()?.ownerId;
      if (owner && owner !== event.params.uid) {
        const who = await profile(event.params.uid);
        await db().collection("notifications").add({
          toUserId: owner,
          fromUserId: event.params.uid,
          fromUserName: who.name,
          fromUserImageUrl: who.imageUrl,
          type: "review",
          businessId: event.params.businessId,
          preview: `${who.name} rated your page ${"★".repeat(Math.max(1, Math.min(5, after.rating || 0)))}`,
          readAt: null,
          hidden: false,
          createdAt: FieldValue.serverTimestamp(),
        });
      }
    }
  },
);

// One-time: fill productCount for pages that already had products.
// Runs every 30 minutes until _maintenance/shop1.done, then does nothing.
exports.shopMaintenance = onSchedule(
  {region: REGION, schedule: "every 30 minutes", timeoutSeconds: 300},
  async () => {
    const stateRef = db().collection("_maintenance").doc("shop1");
    const state = (await stateRef.get()).data() || {};
    if (state.done === true) return;
    const id = admin.firestore.FieldPath.documentId();
    const snap = await db().collection("businesses").orderBy(id)
      .startAfter(String(state.last || "")).limit(200).get();
    for (const doc of snap.docs) await recountProducts(doc.id);
    await stateRef.set({
      last: snap.size ? snap.docs.at(-1).id : "",
      done: snap.size === 0,
      updatedAt: FieldValue.serverTimestamp(),
    }, {merge: true});
  },
);

exports._shopInternals = {cartKey};
