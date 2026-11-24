/**
 * Payment providers.
 *
 * Today Duhuze has one provider: "momo_ussd". The buyer's phone dials the
 * shop's MoMo Pay code (*182*8*1*CODE*AMOUNT#), MTN asks for the PIN, and
 * then the buyer says "I paid" and the shop confirms "Received". No money
 * passes through Duhuze and nothing is verified automatically.
 *
 * When Duhuze signs with a gateway (MTN MoMo API, Paypack, Flutterwave,
 * IremboPay, ...), copy gateway-template.js, fill in its two functions and
 * add it to PROVIDERS below. The app and the order flow stay the same:
 *   - startPayment(order)   -> asks the gateway to charge the buyer
 *   - parseWebhook(request) -> tells us which order was paid or failed,
 *     and shop.js moves the order to "confirmed" or "failed" by itself.
 */
const momoUssd = {
  id: "momo_ussd",
  automatic: false, // the shop confirms by hand

  /** What the app needs to start paying. */
  async startPayment(order) {
    return {
      kind: "ussd",
      // The app fills these into AppConstants.momoPayUssd.
      merchantCode: order.momoCode,
      amount: order.total,
    };
  },
};

const PROVIDERS = {
  [momoUssd.id]: momoUssd,
  // paypack: require("./paypack"),      // example, when ready
};

function getProvider(id) {
  const p = PROVIDERS[id];
  if (!p) throw new Error(`Unknown payment provider: ${id}`);
  return p;
}

module.exports = {PROVIDERS, getProvider};
