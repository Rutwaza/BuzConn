/**
 * One-time move: copies push tokens from users/{uid}.fcmTokens (readable by
 * every signed-in user) to users_private/{uid}.fcmTokens (owner only), then
 * removes them from the public profile.
 *
 * Run once after deploying Phase 1, from the functions folder:
 *   gcloud auth application-default login
 *   node scripts/move-fcm-tokens.js
 */
const admin = require("firebase-admin");

async function main() {
  admin.initializeApp({projectId: process.env.GCLOUD_PROJECT || "bussinessfinder-327f5"});
  const db = admin.firestore();
  const snap = await db.collection("users").where("fcmTokens", "!=", null).get();
  let moved = 0;
  for (const doc of snap.docs) {
    const tokens = (doc.data().fcmTokens || []).filter(Boolean);
    const batch = db.batch();
    if (tokens.length) {
      batch.set(db.collection("users_private").doc(doc.id), {
        fcmTokens: admin.firestore.FieldValue.arrayUnion(...tokens),
      }, {merge: true});
    }
    batch.update(doc.ref, {fcmTokens: admin.firestore.FieldValue.delete()});
    await batch.commit();
    moved += 1;
  }
  console.log(`Moved tokens for ${moved} users.`);
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
