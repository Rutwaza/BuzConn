/**
 * IremboPay gateway, for what people pay Duhuze itself (extra pages,
 * boosted posts). NOT live yet: until the keys below exist, `isReady()` is
 * false and the app shows "Payments are coming soon".
 *
 * How IremboPay works (check every name below against the API docs
 * IremboPay gives you when you sign; they may differ a little):
 *   1. We create an INVOICE (amount + what it is for). IremboPay answers
 *      with an invoiceNumber and a payment link.
 *   2. For MoMo / Airtel Money we ask IremboPay to send a "push" to the
 *      payer's phone; they type their PIN. (Or we open the payment link
 *      for card / other methods.)
 *   3. IremboPay calls our webhook (billingWebhook in billing.js) when the
 *      invoice is paid. We check its signature, then give the item.
 *
 * To turn it on:
 *   1. firebase functions:secrets:set IREMBOPAY_SECRET_KEY
 *   2. In billing.js put "IREMBOPAY_SECRET_KEY" in BILLING_SECRETS.
 *   3. Admin panel -> Payments: fill the account id and product codes,
 *      choose sandbox or live, switch "Payments ready" on.
 *   4. In the IremboPay dashboard, set the webhook (callback) URL to
 *      https://us-central1-bussinessfinder-327f5.cloudfunctions.net/billingWebhook
 */
const crypto = require("crypto");

const BASE_URL = {
  sandbox: "https://api.sandbox.irembopay.com",
  live: "https://api.irembopay.com",
};

const secretKey = () => process.env.IREMBOPAY_SECRET_KEY || "";

/** @param {object} cfg config/billing.irembopay {env, accountId, productCodes} */
function isReady(cfg) {
  return Boolean(secretKey() && cfg?.accountId && cfg?.productCodes);
}

async function call(cfg, path, body) {
  const res = await fetch(`${BASE_URL[cfg.env === "live" ? "live" : "sandbox"]}${path}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "irembopay-secretKey": secretKey(),
      "X-API-Version": "2",
    },
    body: JSON.stringify(body),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok || json.success === false) {
    throw new Error(`IremboPay ${path}: ${res.status} ${json.message || ""}`.trim());
  }
  return json.data || json;
}

module.exports = {
  id: "irembopay",
  automatic: true,
  isReady,

  /**
   * Make the invoice and (for MoMo / Airtel) send the PIN prompt.
   * @param {object} p {id, item, amount, description, payer:{name, email, phone}, network}
   * @param {object} cfg config/billing.irembopay
   * @return {Promise<object>} {kind: "push"|"link", url, providerRef}
   */
  async startPayment(p, cfg) {
    const code = cfg.productCodes[p.item];
    if (!code) throw new Error(`No IremboPay product code for ${p.item}`);
    const invoice = await call(cfg, "/payments/invoices", {
      transactionId: p.id, // our payments/{id}: comes back in the webhook
      paymentAccountIdentifier: cfg.accountId,
      customer: {
        name: p.payer.name || undefined,
        email: p.payer.email || undefined,
        phoneNumber: p.payer.phone || undefined,
      },
      paymentItems: [{code, quantity: 1, unitAmount: p.amount}],
      description: p.description,
      expiryAt: new Date(Date.now() + 2 * 3600000).toISOString(),
      language: "EN",
    });
    const invoiceNumber = invoice.invoiceNumber;
    if (p.payer.phone && (p.network === "MTN" || p.network === "AIRTEL")) {
      await call(cfg, "/payments/transactions/initiate", {
        accountIdentifier: p.payer.phone,
        paymentProvider: p.network,
        invoiceNumber,
        transactionReference: p.id,
      });
      return {kind: "push", providerRef: invoiceNumber, url: invoice.paymentLinkUrl || null};
    }
    return {kind: "link", providerRef: invoiceNumber, url: invoice.paymentLinkUrl || null};
  },

  /**
   * Read IremboPay's webhook. The header looks like
   * "irembopay-signature: t=1700000000000,s=<hex>" where the signature is
   * HMAC-SHA256(secret, `${t}#${rawBody}`).
   * @return {{paymentId: string, providerRef: string, status: "paid"|"failed"}|null}
   */
  parseWebhook(req) {
    const header = String(req.get("irembopay-signature") || "");
    const parts = Object.fromEntries(header.split(",").map((kv) => kv.trim().split("=")));
    const raw = req.rawBody ? req.rawBody.toString("utf8") : JSON.stringify(req.body || {});
    if (!parts.t || !parts.s || !secretKey()) return null;
    const expected = crypto.createHmac("sha256", secretKey()).update(`${parts.t}#${raw}`).digest("hex");
    const a = Buffer.from(expected);
    const b = Buffer.from(String(parts.s));
    if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
    // Refuse old calls (replays): 10 minutes.
    if (Math.abs(Date.now() - Number(parts.t)) > 10 * 60000) return null;
    const data = (req.body && req.body.data) || req.body || {};
    const status = String(data.paymentStatus || "").toUpperCase();
    return {
      paymentId: String(data.transactionId || ""),
      providerRef: String(data.invoiceNumber || ""),
      status: status === "PAID" ? "paid" : (status === "FAILED" || status === "EXPIRED" ? "failed" : "pending"),
      amount: Number(data.amount) || 0,
    };
  },
};
