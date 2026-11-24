// Tests for firestore.rules (Phase 1 security fixes).
// Run:  cd rules-tests && npm install && npm test
// It starts a local Firestore emulator; nothing touches your real database.
const {test, before, beforeEach, after} = require("node:test");
const fs = require("node:fs");
const path = require("node:path");
const {
  initializeTestEnvironment, assertSucceeds, assertFails,
} = require("@firebase/rules-unit-testing");
const {
  doc, getDoc, setDoc, updateDoc, deleteDoc, addDoc, collection,
  arrayUnion, arrayRemove, increment, serverTimestamp,
} = require("firebase/firestore");

let env;
const ALICE = "alice";
const BOB = "bob";
const EVE = "eve";

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-duhuze",
    firestore: {rules: fs.readFileSync(path.join(__dirname, "..", "firestore.rules"), "utf8")},
  });
});

after(async () => env.cleanup());

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, "users/alice"), {name: "Alice", isActive: true});
    await setDoc(doc(db, "posts/p1"), {
      ownerId: ALICE, content: "hello", likes: [BOB], viewCount: 3,
      comments: [{id: "c1", userId: BOB, userName: "Bob", content: "nice", likes: []}],
    });
    await setDoc(doc(db, "chats/alice_bob"), {
      participants: [ALICE, BOB], chatType: "direct", requestStatus: "accepted",
    });
    await setDoc(doc(db, "chats/alice_bob/messages/m1"), {senderId: ALICE, text: "hi"});
    await setDoc(doc(db, "chats/alice_bob/messages/g1"), {senderId: ALICE, text: "x", isGhost: true});
    await setDoc(doc(db, "notifications/n1"), {toUserId: BOB, fromUserId: ALICE, type: "like", readAt: null});
    await setDoc(doc(db, "users_private/alice"), {fcmTokens: ["tok"]});
  });
});

const as = (uid, token = {}) => env.authenticatedContext(uid, token).firestore();

// 1. Likes and comments (Phase 2: their own documents) -------------------
test("a user can like (own like doc) and unlike", async () => {
  const like = doc(as(EVE), "posts/p1/likes/eve");
  await assertSucceeds(setDoc(like, {userId: EVE, createdAt: serverTimestamp()}));
  await assertSucceeds(deleteDoc(like));
});

test("a user cannot like for someone else or remove someone else's like", async () => {
  await assertFails(setDoc(doc(as(EVE), "posts/p1/likes/bob"), {userId: BOB, createdAt: serverTimestamp()}));
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), "posts/p1/likes/bob"), {userId: BOB});
  });
  await assertFails(deleteDoc(doc(as(EVE), "posts/p1/likes/bob")));
});

test("nobody can set like/comment counters or the old lists from the app", async () => {
  await assertFails(updateDoc(doc(as(EVE), "posts/p1"), {likeCount: 9999}));
  await assertFails(updateDoc(doc(as(ALICE), "posts/p1"), {commentCount: 0}));
  await assertFails(updateDoc(doc(as(EVE), "posts/p1"), {likes: arrayUnion(EVE)}));
  await assertFails(updateDoc(doc(as(ALICE), "posts/p1"), {comments: []}));
});

test("comments: write your own, edit your own, like with your own id", async () => {
  const c = doc(as(EVE), "posts/p1/comments/c9");
  await assertSucceeds(setDoc(c, {userId: EVE, userName: "Eve", content: "hi", likes: [], createdAt: serverTimestamp()}));
  await assertFails(setDoc(doc(as(EVE), "posts/p1/comments/c10"), {userId: BOB, userName: "Bob", content: "fake", likes: [], createdAt: serverTimestamp()}));
  await assertFails(setDoc(doc(as(EVE), "posts/p1/comments/c11"), {userId: EVE, userName: "Eve", content: "x", likes: ["a", "b"], createdAt: serverTimestamp()}));
  await assertSucceeds(updateDoc(c, {content: "hi again", editedAt: serverTimestamp()}));
  await assertFails(updateDoc(doc(as(BOB), "posts/p1/comments/c9"), {content: "hacked"}));
  await assertSucceeds(updateDoc(doc(as(BOB), "posts/p1/comments/c9"), {likes: arrayUnion(BOB)}));
  await assertFails(updateDoc(doc(as(BOB), "posts/p1/comments/c9"), {likes: ["x", "y"]}));
});

test("comments: author or post owner may delete, nobody else", async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), "posts/p1/comments/c5"), {userId: BOB, content: "nice", likes: []});
  });
  await assertFails(deleteDoc(doc(as(EVE), "posts/p1/comments/c5")));
  await assertSucceeds(deleteDoc(doc(as(ALICE), "posts/p1/comments/c5")));
});

test("liked_posts list is private", async () => {
  await assertSucceeds(setDoc(doc(as(EVE), "users/eve/liked_posts/p1"), {userId: EVE, createdAt: serverTimestamp()}));
  await assertFails(getDoc(doc(as(BOB), "users/eve/liked_posts/p1")));
});

test("view counter goes up by one only", async () => {
  await assertSucceeds(updateDoc(doc(as(EVE), "posts/p1"), {viewCount: increment(1)}));
  await assertFails(updateDoc(doc(as(EVE), "posts/p1"), {viewCount: 1000}));
});

test("the owner can still edit their post text but not the counters", async () => {
  await assertSucceeds(updateDoc(doc(as(ALICE), "posts/p1"), {content: "edited"}));
  await assertFails(updateDoc(doc(as(ALICE), "posts/p1"), {likeCount: 50}));
  await assertFails(updateDoc(doc(as(EVE), "posts/p1"), {content: "hacked"}));
});

test("a new post must start with no likes or comments", async () => {
  await assertSucceeds(setDoc(doc(as(EVE), "posts/p2"), {ownerId: EVE, likeCount: 0, commentCount: 0}));
  await assertFails(setDoc(doc(as(EVE), "posts/p3"), {ownerId: EVE, likeCount: 500}));
});

// 2 & 3. Messages ------------------------------------------------------------
test("you can only send messages as yourself", async () => {
  const msgs = collection(as(BOB), "chats/alice_bob/messages");
  await assertSucceeds(addDoc(msgs, {senderId: BOB, text: "yo", createdAt: serverTimestamp()}));
  await assertFails(addDoc(msgs, {senderId: ALICE, text: "fake alice"}));
});

test("you cannot edit someone else's message", async () => {
  await assertFails(updateDoc(doc(as(BOB), "chats/alice_bob/messages/m1"), {text: "changed", senderId: BOB}));
  await assertFails(updateDoc(doc(as(BOB), "chats/alice_bob/messages/m1"), {text: "changed"}));
  await assertSucceeds(updateDoc(doc(as(ALICE), "chats/alice_bob/messages/m1"), {text: "fixed typo"}));
});

test("you cannot delete the other person's normal message, but can remove a read ghost message", async () => {
  await assertFails(deleteDoc(doc(as(BOB), "chats/alice_bob/messages/m1")));
  await assertSucceeds(deleteDoc(doc(as(BOB), "chats/alice_bob/messages/g1")));
  await assertSucceeds(deleteDoc(doc(as(ALICE), "chats/alice_bob/messages/m1")));
});

test("outsiders cannot read a chat", async () => {
  await assertFails(getDoc(doc(as(EVE), "chats/alice_bob/messages/m1")));
});

// 4. Notifications -----------------------------------------------------------
test("the app cannot create notifications any more", async () => {
  await assertFails(addDoc(collection(as(EVE), "notifications"),
    {toUserId: BOB, fromUserId: EVE, type: "like"}));
});

test("the receiver can mark a notification read but not rewrite it", async () => {
  await assertSucceeds(updateDoc(doc(as(BOB), "notifications/n1"), {readAt: serverTimestamp()}));
  await assertFails(updateDoc(doc(as(BOB), "notifications/n1"), {type: "follow"}));
  await assertFails(getDoc(doc(as(EVE), "notifications/n1")));
});

// 5. Private user data -------------------------------------------------------
test("push tokens are private", async () => {
  await assertSucceeds(getDoc(doc(as(ALICE), "users_private/alice")));
  await assertFails(getDoc(doc(as(EVE), "users_private/alice")));
});

test("users cannot change server-owned fields on their profile", async () => {
  await assertSucceeds(updateDoc(doc(as(ALICE), "users/alice"), {bio: "hi"}));
  await assertFails(updateDoc(doc(as(ALICE), "users/alice"), {isActive: false}));
  await assertFails(updateDoc(doc(as(ALICE), "users/alice"), {username: "taken.name"}));
  await assertFails(setDoc(doc(as(EVE), "users/eve"), {name: "Eve", apps: {traffic: true}}));
  await assertFails(updateDoc(doc(as(EVE), "users/alice"), {bio: "hacked"}));
});

// 7. Admin -------------------------------------------------------------------
test("admin access comes from the custom claim", async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), "admin_events/e1"), {agencyId: "a1"});
  });
  await assertSucceeds(getDoc(doc(as(EVE, {admin: true}), "admin_events/e1")));
  await assertFails(getDoc(doc(as(EVE), "admin_events/e1")));
  // Unverified email no longer counts.
  await assertFails(getDoc(doc(as(EVE, {email: "nelsonjembe99@gmail.com", email_verified: false}), "admin_events/e1")));
});

test("clear chat only saves my clear time; it no longer deletes for both", async () => {
  await assertSucceeds(updateDoc(doc(as(BOB), "chats/alice_bob"), {"clearedAt.bob": serverTimestamp()}));
  await assertFails(deleteDoc(doc(as(BOB), "chats/alice_bob/messages/m1")));
});

// Phase 3 ---------------------------------------------------------------------
test("feed scores, keywords and timelines are server-only", async () => {
  await assertFails(updateDoc(doc(as(ALICE), "posts/p1"), {trendingScore: 999}));
  await assertFails(setDoc(doc(as(EVE), "posts/p4"), {ownerId: EVE, trendingScore: 5}));
  await assertFails(updateDoc(doc(as(ALICE), "users/alice"), {searchKeywords: ["spam"]}));
  await assertFails(setDoc(doc(as(EVE), "timelines/eve/items/p1"), {postId: "p1"}));
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), "timelines/eve/items/p1"), {postId: "p1"});
  });
  await assertSucceeds(getDoc(doc(as(EVE), "timelines/eve/items/p1")));
  await assertFails(getDoc(doc(as(BOB), "timelines/eve/items/p1")));
});

// Phase 4 ---------------------------------------------------------------------
test("live location: only the sender moves or stops their pin", async () => {
  const pin = {lat: -1.95, lng: 30.06, updatedAt: serverTimestamp()};
  await assertSucceeds(updateDoc(doc(as(ALICE), "chats/alice_bob/messages/m1"), {location: pin}));
  await assertSucceeds(updateDoc(doc(as(ALICE), "chats/alice_bob/messages/m1"), {liveEnded: true, liveUntil: serverTimestamp()}));
  await assertFails(updateDoc(doc(as(BOB), "chats/alice_bob/messages/m1"), {location: pin}));
  await assertFails(updateDoc(doc(as(EVE), "chats/alice_bob/messages/m1"), {location: pin}));
});

test("the ghost archive is closed to every app user", async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), "ghost_archive/alice_bob_g1"), {chatId: "alice_bob"});
  });
  await assertFails(getDoc(doc(as(ALICE), "ghost_archive/alice_bob_g1")));
  await assertFails(getDoc(doc(as(EVE, {admin: true}), "ghost_archive/alice_bob_g1")));
  await assertFails(setDoc(doc(as(ALICE), "ghost_archive/x"), {chatId: "alice_bob"}));
});
