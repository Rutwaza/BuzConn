/**
 * Duhuze earnings: what people pay Duhuze itself (not the shops).
 *
 *   page_slot  one more page (the first page is free, each extra page
 *              is paid once).
 *   boost      show a post higher in For You for some days ("Sponsored").
 *
 * Prices live in `config/billing` (Admin panel -> Payments) and are always
 * read here, never taken from the phone.
 *
 * Every purchase is one `payments/{id}` document:
 *   pending -> paid (item given) | failed | not_ready
 * "not_ready" means the gateway is not switched on yet: the app says
 * "Payments are coming soon" and the team can see who tried (demand).
 *
 * The gateway is IremboPay (payments/irembopay.js). Until it is ready the
 * team can still give items by hand: Admin panel -> Payments -> Give.
 */
const admin = require("firebase-admin");
const {onCall, onRequest, HttpsError} = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");
const irembopay = require("./payments/irembopay");
const {_adminInternals} = require("./admin");

const REGION = "us-central1";
// Add "IREMBOPAY_SECRET_KEY" here once the secret is set (see irembopay.js).
const BILLING_SECRETS = [];

const db = () => admin.firestore();
const {FieldValue, Timestamp} = require("firebase-admin/firestore");
const DAY = 86400000;

const DEFAULTS = {
  ready: false, // switch on in the Admin panel when IremboPay is live
  provider: "irembopay",
  currency: "RWF",
  freePages: 1,
  pageSlotPrice: 5000, // each further page (3rd and more)
  secondPagePrice: null, // the 2nd page; empty = same as pageSlotPrice
  boostPackages: [
    {id: "boost_3d", days: 3, price: 2000},
    {id: "boost_7d", days: 7, price: 4000},
    {id: "boost_14d", days: 14, price: 7000},
  ],
  irembopay: {env: "sandbox", accountId: "", productCodes: {page_slot: "", boost: ""}},
};

async function config() {
  const snap = await db().collection("config").doc("billing").get();
  const c = snap.data() || {};
  return {
    ...DEFAULTS,
    ...c,
    irembopay: {...DEFAULTS.irembopay, ...(c.irembopay || {}),
      productCodes: {...DEFAULTS.irembopay.productCodes, ...((c.irembopay || {}).productCodes || {})}},
    boostPackages: Array.isArray(c.boostPackages) && c.boostPackages.length ?
      c.boostPackages : DEFAULTS.boostPackages,
  };
}

const gatewayReady = (cfg) => cfg.ready === true && cfg.provider === "irembopay" && irembopay.isReady(cfg.irembopay);

/** Pages: how many you may have and how many you use (active pages). */
async function pageSlots(uid, cfg) {
  const [user, pages] = await Promise.all([
    db().collection("users").doc(uid).get(),
    db().collection("businesses").where("ownerId", "==", uid).get(),
  ]);
  const bought = Number((user.data() || {}).pageSlotsBought) || 0;
  const used = pages.docs.filter((d) => d.data().isActive !== false).length;
  const total = (Number(cfg.freePages) || 1) + bought;
  return {free: Number(cfg.freePages) || 1, bought, total, used, canCreate: used < total};
}

/** What the NEXT extra page costs this person: the 2nd page has its own price. */
function nextPagePrice(cfg, slots) {
  const first = slots.bought === 0; // nothing bought yet: this is the 2nd page
  const second = Number(cfg.secondPagePrice);
  if (first && cfg.secondPagePrice !== null && cfg.secondPagePrice !== undefined && second >= 0) return second;
  return Number(cfg.pageSlotPrice);
}

function rwf(n) {
  return `${Number(n).toLocaleString("en-US")} RWF`;
}

async function notify(uid, text, extra = {}) {
  await db().collection("notifications").add({
    toUserId: uid,
    fromUserId: "duhuze",
    fromUserName: "Duhuze",
    fromUserImageUrl: null,
    type: "billing",
    preview: text,
    ...extra,
    readAt: null,
    hidden: false,
    createdAt: FieldValue.serverTimestamp(),
  });
}

/**
 * Give what was paid for. Safe to call twice: `fulfilled` is set in the
 * same transaction.
 */
async function fulfill(paymentId, how) {
  const ref = db().collection("payments").doc(paymentId);
  const result = await db().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) throw new Error(`payment ${paymentId} not found`);
    const p = snap.data();
    if (p.fulfilled) return null;
    if (p.item === "page_slot") {
      tx.set(db().collection("users").doc(p.uid),
        {pageSlotsBought: FieldValue.increment(Number(p.quantity) || 1)}, {merge: true});
    } else if (p.item === "boost") {
      const postRef = db().collection("posts").doc(p.postId);
      const post = await tx.get(postRef);
      if (!post.exists) throw new Error("post gone");
      // A new boost adds its days after the current one ends.
      const current = post.data().boostUntil?.toMillis?.() || 0;
      const start = Math.max(Date.now(), current);
      tx.update(postRef, {
        boostUntil: Timestamp.fromMillis(start + p.days * DAY),
        boostedAt: FieldValue.serverTimestamp(),
        boostPaymentId: paymentId,
      });
    }
    tx.update(ref, {
      status: "paid",
      fulfilled: true,
      paidAt: FieldValue.serverTimestamp(),
      paidHow: how,
      updatedAt: FieldValue.serverTimestamp(),
    });
    return p;
  });
  if (!result) return;
  const text = result.item === "page_slot" ?
    "You can now create one more page. Go to My pages -> New page." :
    `Your post is boosted for ${result.days} days. It now shows in For You as Sponsored.`;
  await notify(result.uid, text, result.postId ? {postId: result.postId} : {});
}

// ------------------------------------------------------------------ app --

/** Prices, whether paying works yet, and my page slots. */
exports.billingInfo = onCall({region: REGION}, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");
  const cfg = await config();
  const pages = await pageSlots(uid, cfg);
  return {
    ready: gatewayReady(cfg),
    currency: cfg.currency,
    pageSlotPrice: cfg.pageSlotPrice,
    secondPagePrice: cfg.secondPagePrice ?? null,
    nextPagePrice: nextPagePrice(cfg, pages),
    boostPackages: cfg.boostPackages,
    pages,
  };
});

/**
 * Start paying for an item.
 * data: {item: "page_slot"|"boost", postId?, packageId?, phone?, network?: "MTN"|"AIRTEL"}
 * Returns {paymentId, status: "pending"|"not_ready", kind?, url?, amount}.
 */
exports.startPurchase = onCall({region: REGION, secrets: BILLING_SECRETS}, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");
  const d = request.data || {};
  const item = String(d.item || "");
  const cfg = await config();
  const user = (await db().collection("users").doc(uid).get()).data() || {};
  if (user.suspended === true) throw new HttpsError("permission-denied", "Your account is suspended.");

  const payment = {
    uid, item, quantity: 1, currency: cfg.currency, provider: cfg.provider,
    status: "pending", fulfilled: false,
    createdAt: FieldValue.serverTimestamp(), updatedAt: FieldValue.serverTimestamp(),
  };
  if (item === "page_slot") {
    payment.amount = nextPagePrice(cfg, await pageSlots(uid, cfg));
    payment.description = "Duhuze: one extra page";
  } else if (item === "boost") {
    const postId = String(d.postId || "");
    const post = postId ? (await db().collection("posts").doc(postId).get()).data() : null;
    if (!post) throw new HttpsError("not-found", "Post not found.");
    if (post.ownerId !== uid) {
      // Page managers may boost the page's posts too.
      const page = post.businessId ? (await db().collection("businesses").doc(post.businessId).get()).data() : null;
      const role = page ? (page.ownerId === uid ? "owner" : (page.team || {})[uid]) : null;
      if (role !== "owner" && role !== "admin") throw new HttpsError("permission-denied", "Only the post owner can boost it.");
    }
    const pkg = cfg.boostPackages.find((p) => p.id === d.packageId);
    if (!pkg) throw new HttpsError("invalid-argument", "Choose a boost package.");
    Object.assign(payment, {
      postId, packageId: pkg.id, days: Number(pkg.days), amount: Number(pkg.price),
      description: `Duhuze: boost a post for ${pkg.days} days`,
    });
  } else {
    throw new HttpsError("invalid-argument", "Unknown item.");
  }
  if (!(payment.amount > 0)) throw new HttpsError("failed-precondition", "This item has no price yet.");

  // One open payment per item at a time (double taps).
  const open = await db().collection("payments").where("uid", "==", uid)
    .where("status", "==", "pending").limit(10).get();
  const twin = open.docs.find((x) => x.data().item === item && (x.data().postId || "") === (payment.postId || "") &&
    Date.now() - (x.data().createdAt?.toMillis?.() || 0) < 10 * 60000);
  if (twin) return {paymentId: twin.id, status: "pending", ...(twin.data().start || {}), amount: twin.data().amount};

  const ref = db().collection("payments").doc();
  if (!gatewayReady(cfg)) {
    await ref.set({...payment, status: "not_ready"});
    return {paymentId: ref.id, status: "not_ready", amount: payment.amount};
  }

  await ref.set(payment);
  try {
    const authUser = await admin.auth().getUser(uid);
    const start = await irembopay.startPayment({
      id: ref.id, item, amount: payment.amount, description: payment.description,
      network: String(d.network || "").toUpperCase(),
      payer: {
        name: user.name || authUser.displayName || "",
        email: authUser.email || "",
        phone: String(d.phone || authUser.phoneNumber || "").replace(/\s+/g, ""),
      },
    }, cfg.irembopay);
    await ref.update({providerRef: start.providerRef, start: {kind: start.kind, url: start.url || null}});
    return {paymentId: ref.id, status: "pending", kind: start.kind, url: start.url || null, amount: payment.amount};
  } catch (e) {
    logger.error("startPurchase", e);
    await ref.update({status: "failed", error: String(e.message || e).slice(0, 300)});
    throw new HttpsError("unavailable", "Could not start the payment. Try again in a moment.");
  }
});

/** IremboPay calls this when an invoice is paid (or fails). */
exports.billingWebhook = onRequest({region: REGION, secrets: BILLING_SECRETS}, async (req, res) => {
  if (req.method !== "POST") return res.status(405).send("POST only");
  const result = irembopay.parseWebhook(req);
  if (!result || !result.paymentId) {
    logger.warn("billingWebhook: bad signature or body");
    return res.status(401).send("bad signature");
  }
  const ref = db().collection("payments").doc(result.paymentId);
  const snap = await ref.get();
  if (!snap.exists) return res.status(404).send("unknown payment");
  const p = snap.data();
  if (result.status === "paid") {
    if (result.amount && result.amount < p.amount) {
      await ref.update({status: "failed", error: `paid ${result.amount}, expected ${p.amount}`});
    } else {
      await fulfill(result.paymentId, "irembopay");
    }
  } else if (result.status === "failed" && p.status === "pending") {
    await ref.update({status: "failed", updatedAt: FieldValue.serverTimestamp()});
  }
  return res.status(200).send("ok");
});

// ---------------------------------------------------------------- admin --

/**
 * Admin panel -> Payments.
 * action "config": save prices / gateway settings (admin only).
 * action "give":   give an item for free {uid, item, postId?, packageId?}.
 * action "markPaid": a payment the team checked by hand {paymentId}.
 */
exports.adminBilling = onCall({region: REGION}, async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in first.");
  if (!_adminInternals.isAdmin(request.auth)) throw new HttpsError("permission-denied", "Admin only.");
  const d = request.data || {};
  const log = (type, data) => db().collection("admin_events").add({
    type, ...data, byUid: request.auth.uid, byEmail: request.auth.token.email || null,
    at: FieldValue.serverTimestamp(),
  });

  if (d.action === "config") {
    const c = d.config || {};
    const clean = {};
    if (typeof c.ready === "boolean") clean.ready = c.ready;
    if (Number.isInteger(c.pageSlotPrice) && c.pageSlotPrice >= 0) clean.pageSlotPrice = c.pageSlotPrice;
    // The 2nd page: its own price, or null to use the same price as the others.
    if (c.secondPagePrice === null) clean.secondPagePrice = null;
    else if (Number.isInteger(c.secondPagePrice) && c.secondPagePrice >= 0) clean.secondPagePrice = c.secondPagePrice;
    if (Number.isInteger(c.freePages) && c.freePages >= 1 && c.freePages <= 10) clean.freePages = c.freePages;
    if (Array.isArray(c.boostPackages)) {
      clean.boostPackages = c.boostPackages.slice(0, 6).map((p, i) => ({
        id: String(p.id || `boost_${i}`), days: Math.max(1, Math.min(60, Number(p.days) || 1)),
        price: Math.max(0, Math.round(Number(p.price) || 0)),
      }));
    }
    if (c.irembopay) {
      clean.irembopay = {
        env: c.irembopay.env === "live" ? "live" : "sandbox",
        accountId: String(c.irembopay.accountId || "").slice(0, 80),
        productCodes: {
          page_slot: String(c.irembopay.productCodes?.page_slot || "").slice(0, 80),
          boost: String(c.irembopay.productCodes?.boost || "").slice(0, 80),
        },
      };
    }
    await db().collection("config").doc("billing").set({...clean, updatedAt: FieldValue.serverTimestamp()}, {merge: true});
    await log("billing_config", {config: clean});
    const cfg = await config();
    return {ok: true, gatewayReady: gatewayReady(cfg), secretSet: Boolean(process.env.IREMBOPAY_SECRET_KEY)};
  }

  if (d.action === "get") {
    const cfg = await config();
    return {config: cfg, gatewayReady: gatewayReady(cfg), secretSet: Boolean(process.env.IREMBOPAY_SECRET_KEY)};
  }

  if (d.action === "give") {
    const uid = String(d.uid || "");
    if (!uid) throw new HttpsError("invalid-argument", "Who?");
    const cfg = await config();
    const ref = db().collection("payments").doc();
    const base = {uid, quantity: 1, amount: 0, currency: cfg.currency, provider: "gift", status: "pending",
      fulfilled: false, givenBy: request.auth.uid, createdAt: FieldValue.serverTimestamp()};
    if (d.item === "page_slot") {
      await ref.set({...base, item: "page_slot", description: "Gift: one extra page"});
    } else if (d.item === "boost") {
      const pkg = cfg.boostPackages.find((p) => p.id === d.packageId) || cfg.boostPackages[0];
      await ref.set({...base, item: "boost", postId: String(d.postId || ""), packageId: pkg.id,
        days: Number(pkg.days), description: `Gift: boost for ${pkg.days} days`});
    } else {
      throw new HttpsError("invalid-argument", "Unknown item.");
    }
    try {
      await fulfill(ref.id, "gift");
    } catch (e) {
      await ref.update({status: "failed", error: String(e.message || e)});
      throw new HttpsError("failed-precondition", String(e.message || e));
    }
    await log("billing_give", {uid, item: d.item, postId: d.postId || null, paymentId: ref.id});
    return {ok: true, paymentId: ref.id};
  }

  if (d.action === "markPaid") {
    const id = String(d.paymentId || "");
    await fulfill(id, "admin");
    await log("billing_mark_paid", {paymentId: id});
    return {ok: true};
  }

  throw new HttpsError("invalid-argument", "Unknown action.");
});

exports._billingInternals = {config, pageSlots, fulfill, nextPagePrice, DEFAULTS};
