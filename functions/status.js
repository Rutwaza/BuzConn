/**
 * Status (24-hour stories).
 *
 * The app writes `statuses/{id}` with `expiresAt` = now + 24h and stops
 * showing it after that. This file:
 *   - counts views (`statuses/{id}/views/{viewerUid}` -> viewCount), and
 *   - deletes expired statuses and their views every hour.
 * Media files stay in R2 (small; a cleanup job for R2 can come later).
 */
const admin = require("firebase-admin");
const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const logger = require("firebase-functions/logger");

const REGION = "us-central1";
const db = () => admin.firestore();

exports.onStatusViewed = onDocumentCreated(
  {region: REGION, document: "statuses/{statusId}/views/{viewerId}"},
  async (event) => {
    await db().collection("statuses").doc(event.params.statusId).update({
      viewCount: admin.firestore.FieldValue.increment(1),
    }).catch(() => {}); // status already deleted
  },
);

exports.cleanupExpiredStatuses = onSchedule(
  {region: REGION, schedule: "every 60 minutes", timeoutSeconds: 300},
  async () => {
    const now = admin.firestore.Timestamp.now();
    let deleted = 0;
    for (let round = 0; round < 10; round++) {
      const snap = await db().collection("statuses")
        .where("expiresAt", "<=", now).limit(200).get();
      if (snap.empty) break;
      for (const doc of snap.docs) {
        await db().recursiveDelete(doc.ref); // the status and its views
        deleted++;
      }
    }
    if (deleted) logger.info(`Deleted ${deleted} expired statuses`);
  },
);
