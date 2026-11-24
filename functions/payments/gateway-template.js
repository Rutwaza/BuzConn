/**
 * TEMPLATE for a real payment gateway (not used yet).
 *
 * Steps when Duhuze is ready:
 *   1. Copy this file to e.g. payments/paypack.js and fill in the two functions.
 *   2. Store the gateway keys as secrets:
 *        firebase functions:secrets:set PAYPACK_CLIENT_ID
 *   3. Add it to PROVIDERS in payments/index.js.
 *   4. In shop.js, set DEFAULT_PROVIDER to its id, and add an HTTPS function
 *      (onRequest) that receives the gateway's webhook and calls
 *      `applyGatewayResult` with what parseWebhook returns.
 *   5. In the app, PaymentMethod.gateway already shows "Waiting for payment…"
 *      and listens to the order until the server marks it paid.
 */
module.exports = {
  id: "my_gateway",
  automatic: true, // the gateway tells us when the buyer paid

  /**
   * Ask the gateway to charge the buyer. Most Rwandan gateways send a MoMo /
   * Airtel Money "push" to the buyer's phone, who just types the PIN.
   * @param {object} order {id, total, currency, buyerPhone, momoCode, ...}
   * @return {Promise<object>} {kind: "push"} or {kind: "redirect", url},
   *   plus providerRef: the gateway's id for this payment.
   */
  async startPayment(order) {
    throw new Error("not implemented");
  },

  /**
   * Read the gateway's webhook call. Always check its signature first.
   * @return {{orderId: string, providerRef: string, status: "paid"|"failed"}}
   */
  parseWebhook(req) {
    throw new Error("not implemented");
  },
};
