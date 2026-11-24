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
 *        |                                   |
 *        +--buyer "Cancel"--> cancelled      +--shop "Not received"--> not_received
 *                                                  (buyer can say "I paid" again)
 *
 * The rules (firestore.rules -> orders) allow exactly these moves.
 * `onOrderWritten` sends the notifications for each move.
 */
const admin = require("firebase-admin");
const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {onDocumentWritten} = require("firebase-functions/v2/firestore");
const {getProvider} = require("./payments");

const REGION = "us-central1";
const DEFAULT_PROVIDER = "momo_ussd";
const MAX_ITEMS = 20;
const MAX_QTY = 99;

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

  const provider = getProvider(DEFAULT_PROVIDER);
  const ref = db().collection("orders").doc();
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
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  };
  const payment = await provider.startPayment({...order});
  await ref.set({...order, payment});
  return {orderId: ref.id, total, payment, momoName: order.momoName};
});

const MESSAGES = {
  // status: [who is told, text]
  pending_payment: ["owner", (o, who) => `${who} ordered ${o.items.length} item(s) · ${rwf(o.total)}`],
  paid_claimed: ["owner", (o, who) => `${who} says they paid ${rwf(o.total)} by MoMo. Check your MoMo messages, then confirm.`],
  cancelled: ["owner", (o, who) => `${who} cancelled an order of ${rwf(o.total)}`],
  confirmed: ["buyer", (o) => `${o.businessName} confirmed your payment of ${rwf(o.total)} ✓`],
  not_received: ["buyer", (o) => `${o.businessName} has not received your ${rwf(o.total)} yet. Check and try again.`],
};

exports.onOrderWritten = onDocumentWritten(
  {region: REGION, document: "orders/{orderId}"},
  async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    if (!after || before?.status === after.status) return;
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
