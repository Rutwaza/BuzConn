/**
 * Pages: creating them (first page free, more pages need a paid slot),
 * restoring a hidden page, and the page team.
 *
 * Page team: the owner adds people by @username.
 *   admin   edits the page, posts as the page, runs the shop and orders.
 *   editor  posts as the page.
 * Stored on the page as `team: {uid: role}` and `teamIds: [uid]` (server
 * only). Orders keep `staffIds` (owner + team admins) so team admins can
 * see and handle them.
 */
const admin = require("firebase-admin");
const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {_billingInternals} = require("./billing");

const REGION = "us-central1";
const MAX_TEAM = 10;
const ROLES = ["admin", "editor"];

const db = () => admin.firestore();
const {FieldValue} = require("firebase-admin/firestore");

function str(v, max) {
  return String(v ?? "").trim().slice(0, max);
}

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

async function activeUser(uid) {
  const user = (await db().collection("users").doc(uid).get()).data() || {};
  if (user.suspended === true) throw new HttpsError("permission-denied", "Your account is suspended.");
  return user;
}

/** data: the page form (name, description, category, address, phone, ...). */
exports.createPage = onCall({region: REGION}, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");
  await activeUser(uid);
  const d = request.data || {};
  const name = str(d.name, 80);
  if (name.length < 2) throw new HttpsError("invalid-argument", "Give the page a name.");

  const cfg = await _billingInternals.config();
  const slots = await _billingInternals.pageSlots(uid, cfg);
  // No free slot: the app opens "Get another page" (not an error).
  if (!slots.canCreate) return {needSlot: true, slots};

  const lat = num(d.latitude);
  const lng = num(d.longitude);
  const address = str(d.address, 200);
  const page = {
    ownerId: uid,
    name,
    description: str(d.description, 1000),
    category: str(d.category, 40) || "Other",
    address,
    location: address,
    phone: str(d.phone, 30),
    momoCode: str(d.momoCode, 20),
    momoName: str(d.momoName, 60),
    email: str(d.email, 120),
    googleMapsLink: str(d.googleMapsLink, 500),
    isVerified: false,
    isActive: true,
    rating: 0,
    reviewCount: 0,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  };
  if (lat !== null && lng !== null && Math.abs(lat) <= 90 && Math.abs(lng) <= 180) {
    Object.assign(page, {latitude: lat, longitude: lng, lat, lng});
  }
  const ref = await db().collection("businesses").add(page);
  await db().collection("users").doc(uid).set({
    businessId: ref.id, userType: "business", updatedAt: FieldValue.serverTimestamp(),
  }, {merge: true});
  return {id: ref.id, slots: {...slots, used: slots.used + 1, canCreate: slots.used + 1 < slots.total}};
});

/** Show a hidden page again (needs a free slot, like creating one). */
exports.restorePage = onCall({region: REGION}, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");
  const pageId = str(request.data?.pageId, 100);
  const ref = db().collection("businesses").doc(pageId);
  const page = (await ref.get()).data();
  if (!page || page.ownerId !== uid) throw new HttpsError("permission-denied", "Not your page.");
  if (page.isActive !== false) return {ok: true};
  if (page.suspended === true) throw new HttpsError("failed-precondition", "This page was suspended by the Duhuze team.");
  const cfg = await _billingInternals.config();
  const slots = await _billingInternals.pageSlots(uid, cfg);
  // No free slot: the app opens "Get another page" (not an error).
  if (!slots.canCreate) return {needSlot: true, slots};
  await ref.update({isActive: true, updatedAt: FieldValue.serverTimestamp()});
  return {ok: true};
});

/** Owner + team admins: who may see and handle the page's orders. */
function staffOf(page) {
  const team = page.team || {};
  return [page.ownerId, ...Object.keys(team).filter((u) => team[u] === "admin")];
}

async function syncOrders(pageId, staffIds) {
  const snap = await db().collection("orders").where("businessId", "==", pageId)
    .orderBy("createdAt", "desc").limit(300).get();
  const writer = db().bulkWriter();
  snap.docs.forEach((d) => writer.update(d.ref, {staffIds}));
  await writer.close();
}

/**
 * data: {pageId, action: "add"|"remove"|"role"|"leave", username?, uid?, role?}
 *   add     owner adds @username with role admin/editor
 *   role    owner changes someone's role
 *   remove  owner removes someone
 *   leave   a member leaves the team
 */
exports.pageTeam = onCall({region: REGION}, async (request) => {
  const me = request.auth?.uid;
  if (!me) throw new HttpsError("unauthenticated", "Sign in first.");
  const d = request.data || {};
  const pageId = str(d.pageId, 100);
  const action = str(d.action, 10);
  const ref = db().collection("businesses").doc(pageId);
  const page = (await ref.get()).data();
  if (!page) throw new HttpsError("not-found", "Page not found.");
  const team = {...(page.team || {})};

  let target = str(d.uid, 128);
  if (action === "add") {
    const username = str(d.username, 40).replace(/^@/, "").toLowerCase();
    const u = username ? (await db().collection("usernames").doc(username).get()).data() : null;
    if (!u?.uid) throw new HttpsError("not-found", `No one has the username @${username}.`);
    target = u.uid;
  }
  if (action === "leave") target = me;
  if (!target) throw new HttpsError("invalid-argument", "Who?");

  if (action !== "leave" && page.ownerId !== me) {
    throw new HttpsError("permission-denied", "Only the page owner manages the team.");
  }
  if (target === page.ownerId) throw new HttpsError("invalid-argument", "The owner is always on the team.");

  if (action === "add" || action === "role") {
    const role = ROLES.includes(d.role) ? d.role : "editor";
    if (action === "add" && !team[target] && Object.keys(team).length >= MAX_TEAM) {
      throw new HttpsError("resource-exhausted", `A page can have up to ${MAX_TEAM} team members.`);
    }
    if (action === "role" && !team[target]) throw new HttpsError("not-found", "Not on the team.");
    team[target] = role;
  } else if (action === "remove" || action === "leave") {
    delete team[target];
  } else {
    throw new HttpsError("invalid-argument", "Unknown action.");
  }

  await ref.update({team, teamIds: Object.keys(team), updatedAt: FieldValue.serverTimestamp()});
  await syncOrders(pageId, staffOf({...page, team})).catch((e) => console.warn("syncOrders", e.message));

  if (action === "add" || action === "role") {
    const owner = (await db().collection("users").doc(page.ownerId).get()).data() || {};
    await db().collection("notifications").add({
      toUserId: target,
      fromUserId: me,
      fromUserName: owner.name || "Page owner",
      fromUserImageUrl: owner.imageUrl || null,
      type: "team",
      businessId: pageId,
      preview: `made you ${team[target] === "admin" ? "an admin" : "an editor"} of ${page.name || "a page"}`,
      readAt: null,
      hidden: false,
      createdAt: FieldValue.serverTimestamp(),
    });
  }
  return {ok: true, team};
});

exports._pagesInternals = {staffOf};
