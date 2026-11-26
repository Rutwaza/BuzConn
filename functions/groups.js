/**
 * Group chats. Every change goes through `groupAction` so the rules stay
 * simple and nobody can make themselves admin from the app.
 *
 * chats/{id} for a group:
 *   chatType: "group", participants: [uid...], admins: [uid...],
 *   ownerId (creator, can't be removed), groupName, groupImageUrl,
 *   groupDescription, onlyAdminsCanSend, onlyAdminsCanEditInfo,
 *   inviteCode (join with a code/link), memberCount
 * Changes are announced in the chat as "system" messages.
 */
const admin = require("firebase-admin");
const crypto = require("crypto");
const {onCall, HttpsError} = require("firebase-functions/v2/https");

const REGION = "us-central1";
const MAX_MEMBERS = 256;
const db = () => admin.firestore();
const {FieldValue} = require("firebase-admin/firestore");

function newCode() {
  return crypto.randomBytes(6).toString("base64url").replace(/[-_]/g, "x").slice(0, 8);
}

async function names(uids) {
  const out = {};
  const refs = uids.map((u) => db().collection("users").doc(u));
  if (!refs.length) return out;
  const snaps = await db().getAll(...refs);
  snaps.forEach((s) => {
    out[s.id] = {exists: s.exists, name: String(s.data()?.name || "Someone"),
      imageUrl: s.data()?.imageUrl || null, suspended: s.data()?.suspended === true};
  });
  return out;
}

async function systemMessage(chatRef, text) {
  await chatRef.collection("messages").add({
    senderId: "system",
    senderName: "Duhuze",
    mediaType: "system",
    text,
    createdAt: FieldValue.serverTimestamp(),
  });
  await chatRef.update({
    lastMessage: text,
    lastMessageAt: FieldValue.serverTimestamp(),
    lastMessageSenderId: "system",
  });
}

function cleanText(v, max) {
  return String(v || "").replace(/\s+/g, " ").trim().slice(0, max);
}

async function loadGroup(chatId, uid) {
  const ref = db().collection("chats").doc(String(chatId || ""));
  const snap = await ref.get();
  const g = snap.data();
  if (!snap.exists || g.chatType !== "group") throw new HttpsError("not-found", "Group not found.");
  const members = (g.participants || []).map(String);
  const admins = (g.admins || []).map(String);
  return {ref, g, members, admins, isMember: members.includes(uid), isAdmin: admins.includes(uid),
    isOwner: g.ownerId === uid};
}

/** Users who blocked [uid] are never added by [uid]. */
async function notBlocking(uid, candidates) {
  const out = [];
  for (const c of candidates) {
    const b = await db().collection("users").doc(c).collection("blocked").doc(uid).get();
    if (!b.exists) out.push(c);
  }
  return out;
}

exports.groupAction = onCall({region: REGION}, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");
  const d = request.data || {};
  const action = String(d.action || "");
  const me = (await names([uid]))[uid];
  if (me?.suspended) throw new HttpsError("permission-denied", "Your account is suspended.");

  if (action === "create") {
    const name = cleanText(d.name, 60);
    if (name.length < 1) throw new HttpsError("invalid-argument", "Give the group a name.");
    let ids = [...new Set((Array.isArray(d.memberIds) ? d.memberIds : []).map(String))]
      .filter((x) => x && x !== uid).slice(0, MAX_MEMBERS - 1);
    const info = await names(ids);
    ids = ids.filter((x) => info[x]?.exists && !info[x].suspended);
    ids = await notBlocking(uid, ids);
    const ref = db().collection("chats").doc();
    const participants = [uid, ...ids];
    await ref.set({
      chatType: "group",
      participants,
      admins: [uid],
      ownerId: uid,
      createdBy: uid,
      groupName: name,
      groupDescription: cleanText(d.description, 300),
      groupImageUrl: String(d.imageUrl || "") || null,
      onlyAdminsCanSend: false,
      onlyAdminsCanEditInfo: true,
      inviteCode: newCode(),
      memberCount: participants.length,
      requestStatus: "none",
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    await systemMessage(ref, `${me.name} created "${name}"`);
    return {chatId: ref.id, added: ids.length};
  }

  if (action === "preview" || action === "join") {
    const code = String(d.code || "").trim();
    if (!/^[A-Za-z0-9]{6,12}$/.test(code)) throw new HttpsError("invalid-argument", "That code doesn't look right.");
    const found = await db().collection("chats").where("inviteCode", "==", code).limit(1).get();
    if (found.empty) throw new HttpsError("not-found", "This invite link is no longer valid.");
    const doc = found.docs[0];
    const g = doc.data();
    const members = (g.participants || []).map(String);
    if (action === "preview") {
      return {chatId: doc.id, name: g.groupName, imageUrl: g.groupImageUrl || null,
        description: g.groupDescription || "", memberCount: members.length,
        alreadyMember: members.includes(uid)};
    }
    if (members.includes(uid)) return {chatId: doc.id, already: true};
    if (members.length >= MAX_MEMBERS) throw new HttpsError("resource-exhausted", "This group is full.");
    if ((g.removedIds || []).includes(uid)) {
      throw new HttpsError("permission-denied", "An admin removed you from this group.");
    }
    await doc.ref.update({participants: FieldValue.arrayUnion(uid),
      memberCount: members.length + 1, updatedAt: FieldValue.serverTimestamp()});
    await systemMessage(doc.ref, `${me.name} joined with the invite link`);
    return {chatId: doc.id};
  }

  const grp = await loadGroup(d.chatId, uid);
  if (!grp.isMember) throw new HttpsError("permission-denied", "You are not in this group.");
  const {ref, g, members, admins} = grp;
  const needAdmin = () => {
    if (!grp.isAdmin) throw new HttpsError("permission-denied", "Only group admins can do this.");
  };

  switch (action) {
    case "add": {
      needAdmin();
      let ids = [...new Set((Array.isArray(d.userIds) ? d.userIds : []).map(String))]
        .filter((x) => x && !members.includes(x));
      if (members.length + ids.length > MAX_MEMBERS) throw new HttpsError("resource-exhausted", `A group can have ${MAX_MEMBERS} members.`);
      const info = await names(ids);
      ids = ids.filter((x) => info[x]?.exists && !info[x].suspended);
      ids = await notBlocking(uid, ids);
      if (!ids.length) return {added: 0};
      await ref.update({participants: FieldValue.arrayUnion(...ids),
        removedIds: FieldValue.arrayRemove(...ids),
        memberCount: members.length + ids.length, updatedAt: FieldValue.serverTimestamp()});
      const who = ids.map((x) => info[x].name);
      await systemMessage(ref, `${me.name} added ${who.slice(0, 3).join(", ")}${who.length > 3 ? ` and ${who.length - 3} more` : ""}`);
      return {added: ids.length};
    }
    case "remove": {
      needAdmin();
      const target = String(d.userId || "");
      if (!members.includes(target)) throw new HttpsError("not-found", "Not in this group.");
      if (target === g.ownerId) throw new HttpsError("permission-denied", "The group creator can't be removed.");
      if (admins.includes(target) && !grp.isOwner) throw new HttpsError("permission-denied", "Only the creator can remove an admin.");
      await ref.update({participants: FieldValue.arrayRemove(target), admins: FieldValue.arrayRemove(target),
        removedIds: FieldValue.arrayUnion(target),
        memberCount: Math.max(0, members.length - 1), updatedAt: FieldValue.serverTimestamp()});
      const t = (await names([target]))[target];
      await systemMessage(ref, `${me.name} removed ${t?.name || "a member"}`);
      return {ok: true};
    }
    case "leave": {
      const rest = members.filter((x) => x !== uid);
      if (!rest.length) {
        await db().recursiveDelete(ref);
        return {deleted: true};
      }
      const update = {participants: FieldValue.arrayRemove(uid), admins: FieldValue.arrayRemove(uid),
        memberCount: rest.length, updatedAt: FieldValue.serverTimestamp()};
      let note = `${me.name} left`;
      const restAdmins = admins.filter((x) => x !== uid);
      if (grp.isOwner || !restAdmins.length) {
        // Hand the group over: oldest remaining admin, else the first member.
        const next = restAdmins[0] || rest[0];
        if (grp.isOwner) update.ownerId = next;
        if (!restAdmins.includes(next)) update.admins = [...restAdmins, next];
        else update.admins = restAdmins;
        const n = (await names([next]))[next];
        note += `. ${n?.name || "A member"} is now ${grp.isOwner ? "the group owner" : "an admin"}`;
      }
      await ref.update(update);
      await systemMessage(ref, note);
      return {ok: true};
    }
    case "promote":
    case "demote": {
      const target = String(d.userId || "");
      if (!members.includes(target)) throw new HttpsError("not-found", "Not in this group.");
      if (action === "promote") {
        needAdmin();
        await ref.update({admins: FieldValue.arrayUnion(target)});
      } else {
        if (!grp.isOwner) throw new HttpsError("permission-denied", "Only the creator can remove admins.");
        if (target === g.ownerId) throw new HttpsError("failed-precondition", "The creator stays admin.");
        await ref.update({admins: FieldValue.arrayRemove(target)});
      }
      const t = (await names([target]))[target];
      await systemMessage(ref, action === "promote" ?
        `${me.name} made ${t?.name || "a member"} an admin` :
        `${t?.name || "A member"} is no longer an admin`);
      return {ok: true};
    }
    case "update": {
      if (g.onlyAdminsCanEditInfo !== false) needAdmin();
      const update = {updatedAt: FieldValue.serverTimestamp()};
      const notes = [];
      if (d.name !== undefined) {
        const name = cleanText(d.name, 60);
        if (!name) throw new HttpsError("invalid-argument", "The name can't be empty.");
        if (name !== g.groupName) {
          update.groupName = name;
          notes.push(`changed the name to "${name}"`);
        }
      }
      if (d.description !== undefined) {
        update.groupDescription = cleanText(d.description, 300);
        notes.push("changed the description");
      }
      if (d.imageUrl !== undefined) {
        update.groupImageUrl = String(d.imageUrl || "") || null;
        notes.push("changed the group photo");
      }
      await ref.update(update);
      if (notes.length) await systemMessage(ref, `${me.name} ${notes.join(" and ")}`);
      return {ok: true};
    }
    case "settings": {
      needAdmin();
      const update = {};
      const notes = [];
      if (typeof d.onlyAdminsCanSend === "boolean" && d.onlyAdminsCanSend !== (g.onlyAdminsCanSend === true)) {
        update.onlyAdminsCanSend = d.onlyAdminsCanSend;
        notes.push(d.onlyAdminsCanSend ? "Only admins can send messages now" : "Everyone can send messages now");
      }
      if (typeof d.onlyAdminsCanEditInfo === "boolean") update.onlyAdminsCanEditInfo = d.onlyAdminsCanEditInfo;
      if (!Object.keys(update).length) return {ok: true};
      await ref.update(update);
      for (const n of notes) await systemMessage(ref, n);
      return {ok: true};
    }
    case "resetInvite": {
      needAdmin();
      const code = newCode();
      await ref.update({inviteCode: code});
      return {inviteCode: code};
    }
    default:
      throw new HttpsError("invalid-argument", "Unknown group action.");
  }
});

exports._groupInternals = {newCode, cleanText};
