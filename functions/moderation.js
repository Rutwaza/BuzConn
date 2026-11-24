/**
 * Moderation: tells the admin team about every new report.
 *
 * The app writes `reports/{id}` (rules: anyone signed in may create, only
 * staff read). This trigger notifies every staff member (`staff/{uid}`,
 * managed in the Admin panel) plus the owner emails in ADMIN_EMAILS, so
 * reports are never missed. Child-safety reports are marked urgent.
 * How to handle a report: README -> "Admin panel", docs/MODERATION.md.
 */
const admin = require("firebase-admin");
const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const logger = require("firebase-functions/logger");

const REGION = "us-central1";
const ADMIN_EMAILS = ["nelsonjembe99@gmail.com"];

exports.onReportCreated = onDocumentCreated(
  {region: REGION, document: "reports/{reportId}"},
  async (event) => {
    const r = event.data?.data();
    if (!r) return;
    const urgent = r.reason === "child_safety";
    const uids = new Set((await admin.firestore().collection("staff").get()).docs.map((d) => d.id));
    for (const email of ADMIN_EMAILS) {
      try {
        uids.add((await admin.auth().getUserByEmail(email)).uid);
      } catch (e) {
        logger.error("Admin email not found", {email, error: e.message});
      }
    }
    for (const uid of uids) {
      try {
        await admin.firestore().collection("notifications").add({
          toUserId: uid,
          fromUserId: String(r.reporterId || ""),
          fromUserName: urgent ? "URGENT report" : "New report",
          fromUserImageUrl: null,
          type: "report",
          reportId: event.params.reportId,
          preview: `${urgent ? "⚠ CHILD SAFETY · " : ""}${r.targetType}: ${r.reason}` +
            (r.details ? ` · ${String(r.details).slice(0, 80)}` : ""),
          readAt: null,
          hidden: false,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      } catch (e) {
        logger.error("Could not notify staff about a report", {uid, error: e.message});
      }
    }
  },
);
