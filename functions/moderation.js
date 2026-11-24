/**
 * Moderation: tells the admin about every new report.
 *
 * The app writes `reports/{id}` (rules: anyone signed in may create, only
 * admins read). This trigger sends a notification to each admin account
 * (ADMIN_EMAILS) so reports are never missed. Child-safety reports are
 * marked urgent. How to handle a report: docs/MODERATION.md.
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
    for (const email of ADMIN_EMAILS) {
      try {
        const user = await admin.auth().getUserByEmail(email);
        await admin.firestore().collection("notifications").add({
          toUserId: user.uid,
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
        logger.error("Could not notify admin about a report", {email, error: e.message});
      }
    }
  },
);
