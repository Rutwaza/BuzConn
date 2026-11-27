/**
 * Ghost message archive.
 *
 * For users, ghost mode works as before: the receiver reads a ghost message
 * and it is wiped from the chat. But when a ghost message is created, the
 * server first copies it, encrypted with AES-256-GCM, into
 * `ghost_archive/{chatId}_{messageId}`. Nobody can read that collection from
 * the app (rules: read/write false). Only a super admin can open a copy, through
 * `decryptGhostArchive`, and every opening is written to `admin_events`.
 *
 * The key lives in Secret Manager as GHOST_ARCHIVE_KEY (32 random bytes, base64).
 * If the key is lost, the archive can never be read again.
 */
const crypto = require("crypto");
const admin = require("firebase-admin");
const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {defineSecret} = require("firebase-functions/params");
const logger = require("firebase-functions/logger");

const REGION = "us-central1";
const GHOST_ARCHIVE_KEY = defineSecret("GHOST_ARCHIVE_KEY");
const SUPER_ADMIN_EMAILS = new Set(["nelsonjembe99@gmail.com"]);

const db = () => admin.firestore();

// --- The app's ghost scramble, so the archive keeps readable text ----------
// Same algorithm as _ghostKeyByte/_decodeGhostText in chat_page.dart.
function ghostKeyByte(index, chatId, senderId, nonce) {
  const block = Math.floor(index / 32);
  const digest = crypto
    .createHmac("sha256", Buffer.from(`${chatId}|${senderId}|spotlight-ghost-v2`, "utf8"))
    .update(`${nonce}|${block}`, "utf8")
    .digest();
  return digest[index % digest.length];
}

function decodeGhostText(cipherText, chatId, senderId, nonce) {
  if (!cipherText || !nonce || !senderId) return "";
  try {
    const bytes = Buffer.from(cipherText, "base64url");
    for (let i = 0; i < bytes.length; i++) {
      bytes[i] ^= ghostKeyByte(i, chatId, senderId, nonce);
    }
    return bytes.toString("utf8");
  } catch (_) {
    return "";
  }
}

// --- Real encryption (AES-256-GCM) ----------------------------------------
function archiveKey() {
  const key = Buffer.from(GHOST_ARCHIVE_KEY.value().trim(), "base64");
  if (key.length !== 32) throw new Error("GHOST_ARCHIVE_KEY must be 32 bytes (base64)");
  return key;
}

function encrypt(plainObject, aad) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", archiveKey(), iv);
  cipher.setAAD(Buffer.from(aad, "utf8"));
  const data = Buffer.concat([
    cipher.update(JSON.stringify(plainObject), "utf8"),
    cipher.final(),
  ]);
  return {
    iv: iv.toString("base64"),
    tag: cipher.getAuthTag().toString("base64"),
    data: data.toString("base64"),
  };
}

function decrypt(box, aad) {
  const decipher = crypto.createDecipheriv(
    "aes-256-gcm", archiveKey(), Buffer.from(box.iv, "base64"));
  decipher.setAAD(Buffer.from(aad, "utf8"));
  decipher.setAuthTag(Buffer.from(box.tag, "base64"));
  const plain = Buffer.concat([
    decipher.update(Buffer.from(box.data, "base64")),
    decipher.final(),
  ]);
  return JSON.parse(plain.toString("utf8"));
}

// --- Trigger: archive every new ghost message -----------------------------
exports.archiveGhostMessage = onDocumentCreated(
  {region: REGION, document: "chats/{chatId}/messages/{messageId}", secrets: [GHOST_ARCHIVE_KEY]},
  async (event) => {
    const m = event.data?.data();
    if (!m || m.isGhost !== true) return;
    const {chatId, messageId} = event.params;
    const senderId = String(m.senderId || "");
    const text = decodeGhostText(
      String(m.ghostCipherText || ""), chatId, senderId, String(m.ghostNonce || ""));

    const archiveId = `${chatId}_${messageId}`;
    const payload = {
      text,
      senderName: m.senderName || null,
      mediaUrl: m.mediaUrl || null,
      mediaType: m.mediaType || null,
      mediaName: m.mediaName || null,
      replyTo: m.replyTo || null,
    };
    const chat = (await db().collection("chats").doc(chatId).get()).data() || {};
    await db().collection("ghost_archive").doc(archiveId).set({
      chatId,
      messageId,
      senderId,
      participants: Array.isArray(chat.participants) ? chat.participants.map(String) : [],
      createdAt: m.createdAt || admin.firestore.FieldValue.serverTimestamp(),
      archivedAt: admin.firestore.FieldValue.serverTimestamp(),
      box: encrypt(payload, archiveId), // text + media, encrypted
      v: 1,
    });
  },
);

// --- Callable: super admin opens archived ghost messages of one chat -------
async function isSuperAdmin(auth) {
  if (!auth) return false;
  if (auth.token?.admin === true) return true;
  return auth.token?.email_verified === true &&
    SUPER_ADMIN_EMAILS.has(String(auth.token.email || "").toLowerCase());
}

exports.decryptGhostArchive = onCall(
  {region: REGION, secrets: [GHOST_ARCHIVE_KEY]},
  async (request) => {
    if (!(await isSuperAdmin(request.auth))) {
      throw new HttpsError("permission-denied", "Super admin only.");
    }
    const chatId = String(request.data?.chatId || "").trim();
    const reason = String(request.data?.reason || "").trim();
    if (!chatId) throw new HttpsError("invalid-argument", "chatId is required.");
    if (reason.length < 5) {
      throw new HttpsError("invalid-argument", "Give a reason (e.g. report id).");
    }
    const limit = Math.min(Math.max(Number(request.data?.limit) || 200, 1), 500);

    const snap = await db().collection("ghost_archive")
      .where("chatId", "==", chatId)
      .orderBy("createdAt", "asc")
      .limit(limit)
      .get();

    const messages = [];
    for (const doc of snap.docs) {
      const a = doc.data();
      try {
        const p = decrypt(a.box, doc.id);
        messages.push({
          messageId: a.messageId,
          senderId: a.senderId,
          createdAt: a.createdAt?.toDate?.().toISOString() || null,
          ...p,
        });
      } catch (e) {
        logger.error("ghost archive decrypt failed", {id: doc.id, error: e.message});
        messages.push({messageId: a.messageId, error: "could not decrypt"});
      }
    }

    await db().collection("admin_events").add({
      type: "ghost_archive_opened",
      chatId,
      reason,
      count: messages.length,
      byUid: request.auth.uid,
      byEmail: request.auth.token.email || null,
      at: admin.firestore.FieldValue.serverTimestamp(),
    });
    return {chatId, count: messages.length, messages};
  },
);

// --- Callables: super admin "Chats" tab ------------------------------------
// 1) adminFindChats: a person's conversations (by email or user id).
// 2) adminReadChat: the whole chat, normal and ghost messages together. Ghost
//    messages are decoded and marked; ones the receiver already read (wiped
//    from the chat) come back from the encrypted archive.
// Both need a written reason and are logged in admin_events.

function needReason(data) {
  const reason = String(data?.reason || "").trim();
  if (reason.length < 5) {
    throw new HttpsError("invalid-argument", "Give a reason (e.g. report id).");
  }
  return reason;
}

function ms(t) {
  return t?.toMillis ? t.toMillis() : 0;
}

exports.adminFindChats = onCall({region: REGION}, async (request) => {
  if (!(await isSuperAdmin(request.auth))) {
    throw new HttpsError("permission-denied", "Super admin only.");
  }
  const reason = needReason(request.data);
  const q = String(request.data?.query || "").trim();
  if (!q) throw new HttpsError("invalid-argument", "Type an email or user id.");
  let uid = q;
  if (q.includes("@")) {
    try {
      uid = (await admin.auth().getUserByEmail(q.toLowerCase())).uid;
    } catch (_) {
      throw new HttpsError("not-found", "No user with that email.");
    }
  }
  const snap = await db().collection("chats")
    .where("participants", "array-contains", uid).limit(200).get();
  const names = {};
  const nameOf = async (id) => {
    if (!(id in names)) {
      const u = (await db().collection("users").doc(id).get()).data() || {};
      names[id] = String(u.name || u.displayName || u.email || id.slice(0, 6));
    }
    return names[id];
  };
  const chats = [];
  for (const d of snap.docs) {
    const c = d.data();
    const parts = (c.participants || []).map(String);
    const people = [];
    for (const id of parts) people.push({uid: id, name: await nameOf(id)});
    chats.push({
      chatId: d.id,
      type: String(c.type || (parts.length > 2 ? "group" : "direct")),
      title: c.groupName || c.name || null,
      people,
      lastMessage: String(c.lastMessage || ""),
      updatedAt: ms(c.lastMessageAt || c.updatedAt || c.createdAt),
    });
  }
  chats.sort((a, b) => b.updatedAt - a.updatedAt);
  await db().collection("admin_events").add({
    type: "chat_search", query: q, reason, count: chats.length,
    byUid: request.auth.uid, byEmail: request.auth.token.email || null,
    at: admin.firestore.FieldValue.serverTimestamp(),
  });
  return {uid, chats};
});

exports.adminReadChat = onCall(
  {region: REGION, secrets: [GHOST_ARCHIVE_KEY]},
  async (request) => {
    if (!(await isSuperAdmin(request.auth))) {
      throw new HttpsError("permission-denied", "Super admin only.");
    }
    const reason = needReason(request.data);
    const chatId = String(request.data?.chatId || "").trim();
    if (!chatId) throw new HttpsError("invalid-argument", "chatId is required.");

    const [msgSnap, archSnap] = await Promise.all([
      db().collection("chats").doc(chatId).collection("messages")
        .orderBy("createdAt", "desc").limit(500).get(),
      db().collection("ghost_archive").where("chatId", "==", chatId)
        .orderBy("createdAt", "desc").limit(500).get(),
    ]);

    const byId = new Map();
    for (const doc of msgSnap.docs) {
      const m = doc.data();
      const ghost = m.isGhost === true;
      byId.set(doc.id, {
        id: doc.id,
        senderId: String(m.senderId || ""),
        senderName: String(m.senderName || ""),
        text: ghost ?
          decodeGhostText(String(m.ghostCipherText || ""), chatId,
            String(m.senderId || ""), String(m.ghostNonce || "")) :
          String(m.text || ""),
        isGhost: ghost,
        wiped: false,
        mediaType: m.mediaType || null,
        mediaName: m.mediaName || null,
        at: ms(m.createdAt),
      });
    }
    // Ghost messages already read and wiped: only the archive still has them.
    for (const doc of archSnap.docs) {
      const a = doc.data();
      if (byId.has(a.messageId)) {
        const live = byId.get(a.messageId);
        if (!live.text) {
          try {
            live.text = decrypt(a.box, doc.id).text || "";
          } catch (_) { /* keep empty */ }
        }
        continue;
      }
      let p = {};
      try {
        p = decrypt(a.box, doc.id);
      } catch (e) {
        logger.error("ghost archive decrypt failed", {id: doc.id, error: e.message});
        p = {text: "(could not decrypt)"};
      }
      byId.set(a.messageId, {
        id: a.messageId,
        senderId: String(a.senderId || ""),
        senderName: String(p.senderName || ""),
        text: String(p.text || ""),
        isGhost: true,
        wiped: true,
        mediaType: p.mediaType || null,
        mediaName: p.mediaName || null,
        at: ms(a.createdAt),
      });
    }
    const messages = [...byId.values()].sort((a, b) => a.at - b.at);
    await db().collection("admin_events").add({
      type: "chat_read", chatId, reason, count: messages.length,
      ghostCount: messages.filter((m) => m.isGhost).length,
      byUid: request.auth.uid, byEmail: request.auth.token.email || null,
      at: admin.firestore.FieldValue.serverTimestamp(),
    });
    return {chatId, count: messages.length, messages};
  },
);

exports._ghostInternals = {decodeGhostText, encrypt, decrypt};
