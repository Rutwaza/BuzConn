/**
 * Gives (or removes) admin rights to a Duhuze account.
 *
 * Run from the functions folder, signed in with the Firebase owner account:
 *   gcloud auth application-default login
 *   node scripts/set-admin.js you@example.com          (make admin)
 *   node scripts/set-admin.js you@example.com --remove (remove admin)
 *
 * The person must sign out and in again (or wait up to 1 hour) for the
 * change to reach their app.
 */
const admin = require("firebase-admin");

async function main() {
  const [email, flag] = process.argv.slice(2);
  if (!email) {
    console.error("Usage: node scripts/set-admin.js <email> [--remove]");
    process.exit(1);
  }
  admin.initializeApp({projectId: process.env.GCLOUD_PROJECT || "bussinessfinder-327f5"});
  const user = await admin.auth().getUserByEmail(email);
  const claims = {...(user.customClaims || {})};
  if (flag === "--remove") delete claims.admin;
  else claims.admin = true;
  await admin.auth().setCustomUserClaims(user.uid, claims);
  console.log(`${email} admin = ${claims.admin === true}`);
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
