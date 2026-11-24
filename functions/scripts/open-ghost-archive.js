/**
 * Opens the encrypted ghost-message archive of ONE chat, from your PC.
 * Use only for a safety report or a legal request. Every use is logged in
 * Firestore `admin_events` (type "ghost_archive_opened").
 *
 * Run from the functions folder, signed in with the Firebase owner account:
 *   gcloud auth application-default login
 *   node scripts/open-ghost-archive.js --chat <chatId> --reason "report #12"
 *   node scripts/open-ghost-archive.js --users alice@x.com bob@y.com --reason "police letter 2026/44"
 *
 * Where things are:
 *   - Encrypted copies: Firestore collection `ghost_archive` (doc id = chatId_messageId)
 *   - The key:          Google Secret Manager, secret GHOST_ARCHIVE_KEY
 *                       (this script reads it with the Firebase CLI)
 * The result is printed and saved in functions/ghost-exports/ (not in Git).
 * Delete that file when the case is closed.
 */
const fs = require("fs");
const path = require("path");
const {execSync} = require("child_process");
const admin = require("firebase-admin");

const PROJECT = process.env.GCLOUD_PROJECT || "bussinessfinder-327f5";

function arg(name) {
  const i = process.argv.indexOf(name);
  return i === -1 ? null : process.argv[i + 1];
}

function loadKey() {
  if (process.env.GHOST_ARCHIVE_KEY) return;
  try {
    process.env.GHOST_ARCHIVE_KEY = execSync(
      `firebase functions:secrets:access GHOST_ARCHIVE_KEY --project ${PROJECT}`,
      {encoding: "utf8", stdio: ["ignore", "pipe", "inherit"]},
    ).trim();
  } catch (e) {
    throw new Error("Could not read GHOST_ARCHIVE_KEY. Run `firebase login` first.");
  }
}

async function findChat(db, emailA, emailB) {
  const a = await admin.auth().getUserByEmail(emailA);
  const b = await admin.auth().getUserByEmail(emailB);
  const snap = await db.collection("chats").where("participants", "array-contains", a.uid).get();
  const hits = snap.docs.filter((d) => (d.data().participants || []).includes(b.uid));
  if (hits.length === 0) throw new Error("These two users have no chat together.");
  if (hits.length > 1) {
    console.log("Several chats found, using the first. All ids:", hits.map((d) => d.id).join(", "));
  }
  return hits[0].id;
}

async function main() {
  const reason = arg("--reason");
  let chatId = arg("--chat");
  const usersAt = process.argv.indexOf("--users");
  if (!reason || reason.length < 5 || (!chatId && usersAt === -1)) {
    console.error("Usage: node scripts/open-ghost-archive.js (--chat <chatId> | --users <emailA> <emailB>) --reason \"why\"");
    process.exit(1);
  }

  admin.initializeApp({projectId: PROJECT});
  const db = admin.firestore();
  if (!chatId) {
    chatId = await findChat(db, process.argv[usersAt + 1], process.argv[usersAt + 2]);
  }

  loadKey();
  const {decrypt} = require("../ghost.js")._ghostInternals;

  const snap = await db.collection("ghost_archive")
    .where("chatId", "==", chatId).orderBy("createdAt", "asc").get();
  const messages = snap.docs.map((doc) => {
    const a = doc.data();
    try {
      return {
        messageId: a.messageId,
        senderId: a.senderId,
        createdAt: a.createdAt?.toDate?.().toISOString() || null,
        ...decrypt(a.box, doc.id),
      };
    } catch (e) {
      return {messageId: a.messageId, error: "could not decrypt (wrong key?)"};
    }
  });

  let operator = "owner-script";
  try {
    operator = execSync("gcloud config get-value account", {encoding: "utf8"}).trim() || operator;
  } catch (_) {/* gcloud not on PATH: keep default */}
  await db.collection("admin_events").add({
    type: "ghost_archive_opened",
    chatId,
    reason,
    count: messages.length,
    byEmail: operator,
    via: "scripts/open-ghost-archive.js",
    at: admin.firestore.FieldValue.serverTimestamp(),
  });

  const dir = path.join(__dirname, "..", "ghost-exports");
  fs.mkdirSync(dir, {recursive: true});
  const file = path.join(dir, `${chatId}_${Date.now()}.json`);
  fs.writeFileSync(file, JSON.stringify({chatId, reason, messages}, null, 2));

  for (const m of messages) {
    console.log(`[${m.createdAt}] ${m.senderName || m.senderId}: ${m.text || m.mediaUrl || m.error || ""}`);
  }
  console.log(`\n${messages.length} ghost message(s). Saved to ${file}`);
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
