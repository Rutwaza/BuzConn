# Duhuze

Duhuze ("let's connect", Africa Connected; formerly SpotLight/BussFinder) is a Flutter social app for discovering creators and businesses, publishing image/video posts, and communicating through direct or business chats. Firebase provides identity, application data, realtime updates and push notifications. Cloudflare R2 stores media; authenticated Firebase Functions issue short-lived upload/download links.

This README is the setup and release handoff for the current repository. It describes the configuration found in this checkout, including gaps that must be closed before a public release. Do not treat a successful debug run as a production readiness check.

## Duhuze handbook: read this first

The short version of everything important. Details are further down.

### Where we are (November 2026)

| Phase | What | State |
| --- | --- | --- |
| 1 | Security rules, rename to Duhuze, admin claim | Live |
| 2 | Fast chat (no transactions, offline cache, paging), likes/comments as subcollections, RTDB presence/typing | Live |
| 3 | Video compression, reel preloading, server feeds (Reels, Following timelines, trending), keyword search, unread badge | Live |
| 4 | Location in chat (live + background), ghost archive, Shop + MoMo Pay, **Status** (24h), **Kinyarwanda**, **Lite mode** | Code done; deploy + phone test |
| 5 | Release readiness: account deletion (server), report & block, legal website, app id `rw.duhuze.app`, release signing, API 36, store assets, docs | Code done; follow **docs/RELEASE.md** |

Work happens on the Git branch `phase-1`; `main` is the old app.

**Release documentation** (start here when you get a phone):

| Doc | Use |
| --- | --- |
| [docs/TESTING.md](docs/TESTING.md) | Phone test checklist, feature by feature |
| [docs/RELEASE.md](docs/RELEASE.md) | From this repo to Google Play, first time and every update |
| [docs/PLAY_LISTING.md](docs/PLAY_LISTING.md) | Store texts, images and every Play Console form answer |
| [docs/MODERATION.md](docs/MODERATION.md) | Reports, blocks, child safety, ghost archive use |

Release tools (PowerShell, in `tools/`): `create-upload-key.ps1` (once),
`register-android-app.ps1` (once, and again with the Play signing SHA-1),
`build-release.ps1` (every release). Public website pages: `site/` (deployed
by `deploy.ps1` as Firebase Hosting, refuses while `CHANGE_ME` placeholders remain).

### Names: what users see vs. internal names

Everything users and Google Play see is **Duhuze**: app name, icon, app id
`rw.duhuze.app` (after `tools/register-android-app.ps1`), website
**https://duhuze-rw.web.app** (Firebase Hosting site `duhuze`), store listing.

These old names stay **on purpose**. They are invisible to users, and changing them would break things:

| Internal name | Why it stays |
| --- | --- |
| Firebase project id `bussinessfinder-327f5` | Google never allows renaming a project id. Moving to a new project means moving every user and all data. |
| Dart package `businessfinder` (imports `package:businessfinder/...`) | Only the code sees it; renaming touches every file for no user benefit. |
| Kotlin namespace `com.example.bussinessfinder` (MainActivity) | The namespace does not have to match the app id; Play only sees `rw.duhuze.app`. |
| `spotlight/privacy`, `spotlight/calls` method channels | Names shared between Dart and Kotlin; both sides must change together. |
| `spotlight-ghost-v2` in the ghost scramble | **Never change**: old ghost messages and the archive would no longer decode. |
| Notification channel ids `spotlight_chat/_activity/_calls` | Their *names* already say "Duhuze Chats" etc.; the ids are used by the server's push messages. |
| R2 buckets `bussinessfinder-public/-private` | Bucket names cannot be renamed; media URLs depend on them. |
| Folder `BussFinder\bussinessfinder` | Only on your PC. Rename the folder any time if you like (close VS Code / Android Studio first). |

### Deploying (always use the script)

```powershell
cd C:\Users\Nexon\Desktop\PROJECTS\BussFinder\bussinessfinder
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -DryRun   # show the plan only
powershell -ExecutionPolicy Bypass -File .\deploy.ps1           # deploy what changed
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -All      # everything (slow, ~15 min)
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -Functions createOrder,onOrderWritten
```

- It only deploys what changed since the commit saved in `.deploy-state` (a local file, not in Git). Rules, indexes and database rules go by file; functions go by the file they live in (`functions/scripts/function-map.js` lists them).
- Everything is redeployed when `functions/package*.json` or `setGlobalOptions` in `functions/index.js` changes.
- Functions go up 4 at a time with a pause. Google's per-region **CPU quota** fails a deploy of ~30 functions at once ("Quota exceeded for total allowable CPU"). That is also why `setGlobalOptions` uses `cpu: "gcf_gen1"`, `memory: "256MiB"`, `maxInstances: 10`. Raise these only when traffic needs it.
- If a deploy fails, the old version keeps running, so the app does not break. Re-run with the `-Functions` list the script prints.
- Lost `.deploy-state`? The script deploys everything once and starts again from there.

### ⚠ Critical: ghost message archive

Ghost messages disappear from the chat after the receiver reads them, but the server keeps an **encrypted copy**.

| What | Where |
| --- | --- |
| Encrypted copies | Firestore collection `ghost_archive` (doc id `chatId_messageId`). Rules: nobody can read or write from the app. |
| The key | Google Secret Manager → secret **`GHOST_ARCHIVE_KEY`** (Google Cloud console → Security → Secret Manager, project `bussinessfinder-327f5`). Made once by `deploy.ps1`. |
| Code | `functions/ghost.js` (`archiveGhostMessage` trigger, `decryptGhostArchive` admin callable) |
| Log of every opening | Firestore `admin_events`, type `ghost_archive_opened` |

**To open a chat's ghost messages** (only for a safety report or legal request):

```powershell
cd functions
gcloud auth application-default login     # once (install gcloud first: see "PC tools for owner scripts")
firebase login                            # the script reads the key with the CLI
node scripts/open-ghost-archive.js --users alice@example.com bob@example.com --reason "report #12"
# or, if you know the chat id (Firestore -> chats):
node scripts/open-ghost-archive.js --chat <chatId> --reason "police letter 2026/44"
```

It prints the messages and saves them in `functions/ghost-exports/` (not in Git). Delete that file when the case is closed.

**Rules for the key:**
- **Never delete or replace `GHOST_ARCHIVE_KEY`.** Without it, the archive can never be read again. A new key does not open old copies.
- Do not copy the key into chats, files or this README.
- The privacy policy must say: *ghost messages disappear from your chat, but Duhuze keeps an encrypted copy that can only be opened for safety reports or legal requests.* (Have it checked against Rwanda's data protection law before launch.)
- Only messages sent after the archive went live are saved; older ghosts are gone.

### ⚠ Critical: payments (MoMo now, gateway later)

**Today (no gateway):** businesses enter their **MoMo Pay merchant code** and the name registered on MoMo (Edit page → `businesses/{id}.momoCode`, `momoName`).
1. The buyer picks products in the Shop. The server function `createOrder` builds the order with the **real prices** from the catalog.
2. The phone dialer opens with `*182*8*1*CODE*AMOUNT#`. The template is `AppConstants.momoPayUssd`. **Check this format on a real MTN line**; if MTN does not take the amount, use `'*182*8*1*{code}#'`.
3. The buyer enters the PIN in MTN's pop-up, then taps "Yes, I paid" (optionally with the transaction ID from the SMS) or "Cancel".
4. The shop checks its own MoMo SMS and taps **Received ✓** or **Not received**.

Nothing is verified automatically, and Duhuze never holds money. Android does not let apps read the USSD reply, and Google Play does not allow reading SMS.

Order states (rules allow only these moves): `pending_payment → paid_claimed → confirmed → ready → delivered` (the shop may also go `confirmed → delivered` directly), `paid_claimed → not_received → paid_claimed`, and `pending_payment/not_received → cancelled`. Buyers see this as a tracking line: Ordered → Paid → Confirmed → Ready → Delivered, with a notification at every step (`onOrderWritten`).

**No double orders.** The app makes one `requestId` per checkout and the second tap is ignored while the first runs. The server turns `requestId` into the order's id, so the same request always returns the same order (a retry on a bad connection never makes a second one). An identical unpaid cart from the same buyer in the last 5 minutes is also reused (`cartKey`).

#### How a shop works (for page owners)

1. **Edit page →** fill in **MoMo Pay merchant code** and **Name registered on MoMo Pay**.
2. Open **My shop** (page profile, or the desktop side menu → Shop → My shop) and **Add product** (name, price in RWF, photo, in stock).
3. When you post **as the page**, pick **Tag a product**: the post shows **Buy · price** and opens the shop with that product in the cart. Posts from pages with products get a **🛍 Shop** button.
4. **Orders** (receipt icon in the shop, or side menu → Orders → *My shop* tab): check your MoMo SMS for the amount and transaction ID, then **Received ✓**, later **Ready** and **Mark delivered**.
5. The page profile shows **Popular in this shop** (best sellers first; `soldCount` is counted by the server when an order is confirmed) and **Reviews** (1–5 stars, one per person; the average is kept by `onReviewWritten`).

Server-only page fields (owners can't write them): `productCount` (feeds the Shop button; filled for old pages by the one-time `shopMaintenance` job), `verified*`, `ratingAvg`, `ratingCount`; and `products/*.soldCount`.

**When Duhuze is ready for a real gateway**, the plug-in points are already there:

- [ ] Pick a provider that sends a MoMo/Airtel "push" to the buyer and calls our server back (webhook). Candidates to compare: MTN MoMo Open API (Collections), Paypack, Flutterwave, IremboPay. Compare fees, settlement time, KYC for merchants, sandbox.
- [ ] Copy `functions/payments/gateway-template.js` to `functions/payments/<provider>.js` and fill in `startPayment` and `parseWebhook`.
- [ ] Store its keys: `firebase functions:secrets:set <PROVIDER>_KEY` (never in code).
- [ ] Register it in `functions/payments/index.js` and set `DEFAULT_PROVIDER` in `functions/shop.js`.
- [ ] Add an HTTPS webhook function in `shop.js` that checks the signature and sets the order to `confirmed` (or `failed`). Add `failed` to the rules and to `OrderStatus` in the app.
- [ ] In the app, add a class next to `MomoUssdPayment` in `lib/features/shop/data/payment_methods.dart` with `automatic = true`, and return it from `PaymentMethods.current`. The pay sheet should then wait for the server instead of asking "Did it go through?".
- [ ] Decide whether shops still get paid directly (marketplace split) or Duhuze collects and pays out. The second makes Duhuze hold money, which needs a licence; ask a lawyer first.

### Admin panel: who is admin and how to moderate

> **PC tools for owner scripts (once per PC).** `set-admin.js` and
> `open-ghost-archive.js` sign in to Google with the **Google Cloud CLI**:
> ```powershell
> winget install --id Google.CloudSDK -e      # then open a NEW PowerShell window
> gcloud auth application-default login        # browser: pick the owner account, Allow
> gcloud auth application-default set-quota-project bussinessfinder-327f5
> ```
> Without this the scripts fail with `getaddrinfo ENOTFOUND metadata.google.internal`.

**Who is who**

| Role | Who | Can do | How you become it |
| --- | --- | --- | --- |
| **Admin** | The owner, `nelsonjembe99@gmail.com` | Everything below, plus add or remove moderators, open the ghost archive (from the PC), see `admin_events` | `cd functions; node scripts/set-admin.js <email>` (from the PC, after the one-time gcloud setup above) |
| **Moderator** | Trusted helpers you choose | Read and handle reports, suspend and restore users | The admin adds them in the app: Admin panel → **Team** → *Add moderator* |
| Everyone else | Normal users | Report and block | Nothing |

Roles are **custom claims** on the Firebase account (`admin: true` or
`moderator: true`), so nobody can give themselves a role from the phone. The
team list is in Firestore `staff/{uid}`. After a role change the person must
**sign out and in again** (or wait up to 1 hour).

> First time: run `node scripts/set-admin.js nelsonjembe99@gmail.com` once,
> sign out and in. Until then a temporary fallback treats that verified email
> as admin. Remove the fallback afterwards (see the checklist below).

**Opening the panel**

App → **Settings → Admin panel** (moderators see *Moderator panel*). The tile
only appears for staff. Tapping a report notification also opens it. Every
staff member gets a notification for each new report; child-safety reports
say **URGENT**.

**The sections** (left rail on PC, ☰ menu on phones)

1. **Dashboard**: counts at a glance (people, pages, posts, groups, open reports, verification requests, orders and "not received" disputes, suspended, verified, new people this week, new posts today). Tap a card to jump to its section. A red banner shows waiting child-safety reports. Admins can **Send announcement** (a notification to every active user, up to 5,000; logged).
2. **Reports**
   - *Open* is the to-do list (child safety always first); *Handled* is the history.
   - Tap a report to see the reported person, the post or status (photo + text), the reporter's note, and the actions:
     - **Dismiss**: nothing wrong.
     - **Remove post/status**: deletes it with its likes, comments and views. A copy is kept in the locked Firestore collection `evidence` (for the police), and photo/video files stay in R2.
     - **Suspend user**: logs them out everywhere and blocks sign-in; their posts are hidden from feeds.
     - **Remove + suspend**: both at once.
   - Write a short note (why). It is saved on the report.
3. **Users**: *Newest*, *Suspended*, *Verified*, or search one word of a name/username. Tap a person for the full picture: email/phone (and if verified), sign-in method, join date, last sign-in, posts, followers, reports against them, "strikes" (reports that led to action), orders, their pages. Actions: **Open profile**, **Send warning** (they get a "Message from the Duhuze team" notification), **Verify ✓ / Remove ✓** (admin), **Suspend** (with a reason, logged) / **Restore account**.
4. **Pages**: *Newest*, *Shops*, *Verified*, *Suspended*, or search. Tap a page: followers, posts, products, orders, reports, rating, MoMo set or not. Actions: **Open page**, **Owner** (opens the person), **Verify ✓ / Remove ✓** (admin), **Suspend page** (with a reason the owner sees) / **Restore page**. A suspended page disappears from feeds and search, its shop refuses orders, and the owner can't edit it, post as it or change products (enforced in `firestore.rules`).
5. **Verification** (admin): requests for the blue ✓. They only arrive when every rule is met (see *Verification* below), each with its checklist. **Look at it**, then **Approve** or **Reject** (with a note the person sees). They get a notification either way.
6. **Orders**: *Not received* (buyer says paid, shop says no money: compare the MoMo transaction ID; open the **Shop** or the **Buyer** to act) and *Latest* orders with their tracking line.
7. **Activity** (admin): every team action from `admin_events`: who did what, when, with notes. Tap a line to open the person or page.
8. **Team** (admin only): see the team, **Add moderator** by email (they need a Duhuze account), remove a moderator.

**Rules for the team**

- Aim to handle reports within **24 hours**, child safety **immediately** (steps in `docs/MODERATION.md`: remove + suspend, do not download or forward anything, keep the evidence, report to RIB).
- Chats are private and are **not** shown in the panel. Only the admin may open messages for a specific report, from the PC (ghost archive script above, or `exportChatBetweenUsers`), and every opening is logged.
- Suspended people see "This account is suspended. Contact Duhuze support." when they try to sign in. Restore them from **Users** if it was a mistake.
- Every action is checked on the server (`functions/admin.js`) and written to Firestore `admin_events`: who, what, when, which report or user. Moderators cannot suspend an admin or change the team.

**Where things are in the code**

| Part | File |
| --- | --- |
| Panel screens | `lib/features/admin/admin_panel_page.dart` |
| Role check + calls | `lib/features/admin/admin_service.dart` |
| Server actions: `adminResolveReport`, `adminSetUserSuspended`, `adminSetPageSuspended`, `adminSetRole`, `adminSetVerified` (page), `adminSetUserVerified`, `adminReviewVerification`, `adminWarnUser`, `adminUserDetails`, `adminBroadcast`, `adminStats` | `functions/admin.js` |
| Verified badge (✓): Admin panel, or on a page **Verify this page** (admins only see the button) | `lib/features/admin/admin_verify_button.dart` |
| "Get verified" requests and their rules | `functions/verification.js`, `lib/features/verification/verification_sheet.dart` |
| Report alerts to the team | `functions/moderation.js` (`staff` + `ADMIN_EMAILS`) |
| Who can read `reports` / `staff` | `firestore.rules` (`isStaff()`) |
| Report & block for users | `lib/features/moderation/moderation.dart` |

**If you lose access** (changed email, new account): from the PC run
`node scripts/set-admin.js <new email>` (needs the Firebase owner Google
account), then `node scripts/set-admin.js <old email> --remove`.

### Verification (the blue ✓)

People ask in **Settings → Get verified**; page owners on their page → **Get verified**. The app shows a checklist from the server; the request button only appears when everything is ✓:

| Rule | Person | Page |
| --- | --- | --- |
| Age | account ≥ 30 days | page ≥ 14 days |
| Profile | photo, name, bio (10+ letters) | logo, description (20+ letters), category |
| Contact | verified email or a phone number | phone + location/address |
| Activity | ≥ 3 posts, ≥ 25 followers | ≥ 3 posts, ≥ 25 followers |
| Clean record | not suspended, no removed content in 90 days | same for the owner; page not suspended |

Change the numbers in `RULES` at the top of `functions/verification.js`. After a rejection they can ask again after 30 days. `verified` on `users`/`businesses` can only be written by the server.

### Group chats

Inbox → **New group** (or the ✏️ button → *New group*): pick people (the people you follow / who follow you come first, or search), then a name, photo and description. In the group: tap the name at the top for **Group info**.

- **Roles:** the creator is the **owner**; admins can add and remove members, make admins, change info and settings, and reset the invite link. Only the owner can remove an admin. If the owner leaves, the next admin (or the oldest member) becomes owner. Up to 256 members.
- **Settings:** *Only admins can send messages* (announcement groups) and *Only admins can edit group info*.
- **Invite link:** `https://duhuze-rw.web.app/g/<code>`. On Android it opens the app; anywhere, Inbox → 🔗 *Join a group* takes the link or the code. People removed by an admin can't rejoin with the link (only an admin can add them back).
- Changes appear in the chat as small grey lines ("Alice added Bob"), written by the server.
- Group calls and ghost mode are not available in groups yet.
- **Code:** server `functions/groups.js` (`groupAction`), app `lib/features/chat/ui/group_pages.dart`, `people_picker.dart`, `lib/features/chat/data/group_service.dart`. Group fields (`admins`, `groupName`, `onlyAdminsCanSend`, …) can only change through the server (`groupFieldsUnchanged()` in the rules).

### Sharing posts and links

The ➤ button on a post (or ⋯ → Share) opens the share sheet:

- **Send to** several chats or groups at once (recent chats first, 🔍 for anyone), with an optional note. It arrives as a post card in the chat; tapping it opens the post.
- **Add to story**: the post's photo + caption as your 24-hour status, with a **View post** button for viewers.
- **Copy link**: `https://duhuze-rw.web.app/p/<postId>`. The website shows a preview (photo, author, caption) and an **Open in the Duhuze app** button; on Android the link opens the app directly.
- **Share to…**: the phone/PC share menu (WhatsApp, Telegram, email…), via the `share_plus` package.
- Website pages: `site/p.html`, `site/g.html` (rewrites in `firebase.json`). App routes `/p/:id` and `/g/:code` (`lib/core/routes/router.dart`); Android links in `AndroidManifest.xml`. To skip Android's "Open with" question later, add `site/.well-known/assetlinks.json` with the Play app-signing SHA-256 and set `android:autoVerify="true"`.

### Other things that must not be forgotten

- [ ] **Admin:** run `node scripts/set-admin.js nelsonjembe99@gmail.com` (from `functions/`), sign out and in, then remove the email fallback: `isSuperAdmin` in `firestore.rules`, `SUPER_ADMIN_EMAILS` in `functions/index.js` and `functions/ghost.js`, `OWNER_EMAILS` in `functions/admin.js`, `_ownerEmails` in `lib/features/admin/admin_service.dart`.
- [ ] **One-time jobs:** when Firestore `_maintenance/phase2`, `_maintenance/phase3` and `_maintenance/shop1` show `done: true`, delete `phase2Maintenance` (social.js), `phase3Maintenance` (feed.js) and `shopMaintenance` (shop.js), then deploy. Until phase3 is done, old posts still show: the feed falls back to reading them by date.
- [ ] **Map tiles:** chat maps use OpenStreetMap's free server (`AppConstants.mapTileUrl`). Switch to a paid provider (MapTiler, Stadia, …) before a big launch.
- [ ] **Live location:** works in the background through an Android foreground service (`lib/features/chat/data/live_location_service.dart`). It stops if the user swipes the app away, and resumes when that chat is opened again. Google Play will ask why the app uses `FOREGROUND_SERVICE_LOCATION`; the answer is "live location sharing in chat".
- [ ] **App id:** run `tools/register-android-app.ps1` (docs/RELEASE.md step 4). Until then builds keep `com.example.bussinessfinder`.
- [ ] **Separate dev and production Firebase projects** before real users arrive.
- [ ] **Firebase Functions SDK:** `firebase-functions` is on v5 (deploy warns "outdated"). Upgrade it with care, because it has breaking changes.
- [ ] **Rules tests:** run them after every change to `firestore.rules` (`cd rules-tests; npm test`, needs Java).
- [ ] **Website placeholders:** replace `CHANGE_ME_EMAIL` / `CHANGE_ME_OWNER` in `site/*.html`, then `deploy.ps1` publishes them.
- [ ] **Kinyarwanda review:** a native speaker reads `lib/core/i18n/rw_strings.dart` (drafted with AI help). Server notification texts (functions) are still English only.
- [ ] **NCSA registration:** Rwanda's data protection law requires registering as a data controller; storing data with Google/Cloudflare outside Rwanda needs their authorization.
- [ ] **Report alerts** go to everyone in the Admin panel's Team plus `ADMIN_EMAILS` in `functions/moderation.js`.
- [ ] **R2 media of expired statuses** is not deleted yet (only the Firestore docs). Add an R2 lifecycle rule for `public/post-*/…/status/` or a cleanup job when storage grows.

### Where the data lives

| Collection | What | Who writes |
| --- | --- | --- |
| `users`, `users_private` | Profiles; push tokens + unread counter (private) | Owner (server fields locked) / server |
| `businesses`, `businesses/{id}/products` | Pages incl. `momoCode`; shop catalog | Business owner (server: `productCount`, `verified`, ratings, `soldCount`) |
| `businesses/{id}/reviews/{uid}` | One review per person (1–5 stars + text) | That person (not the page owner); average by server |
| `orders` | Shop orders | `createOrder` (server), then buyer/owner status moves |
| `posts`, `posts/{id}/likes`, `posts/{id}/comments` | Feed content | Users; counters by server |
| `timelines/{uid}/items` | Following feed | Server only |
| `chats/{id}` (`chatType`: direct, business, **group**) | Chats; groups add `admins`, `ownerId`, `groupName`, `inviteCode`, settings | Participants; group fields only via `groupAction` |
| `chats/{id}/messages` | Messages (incl. `location`, live location, `sharedPost`; `mediaType: system` lines in groups) | Participants; system lines by the server |
| `verification_requests/{kind}_{id}` | Blue ✓ requests with their checklist | Server only; the requester and admins read |
| `ghost_archive` | Encrypted ghost copies | Server only, nobody reads from the app |
| `statuses`, `statuses/{id}/views` | 24h statuses and who viewed them | Owner creates/deletes; viewer adds own view; server counts + cleans up hourly |
| `users/{uid}/blocked/{otherUid}` | People I blocked | Only me |
| `reports` | Reports of posts/users/chats/statuses | Anyone creates; staff read; only the server (Admin panel actions) changes them |
| `evidence` | Copies of removed reported content, for the authorities | Server only; nobody reads from the app (Firebase console only) |
| `staff` | Admin/moderator team list | Server only (`adminSetRole`, `set-admin.js`); staff read |
| `admin_events` | Log of every admin action, ghost archive opening, account deletion | Server only; admins read |
| `notifications` | In-app + push notifications | Server only |
| `admin_events` | Admin actions log | Server only |
| Realtime DB `status/{uid}`, `typing/{chatId}/{uid}` | Online + typing | Each user for themselves |


## Project ownership and services

| Service | Account used for this project |
| --- | --- |
| Cloudflare / R2 | `batman006rtz@gmail.com` |
| Firebase / Google Cloud project | `nelsonjembe99@gmail.com` |

These are account identifiers only. Passwords, recovery codes, API secrets, service-account keys, R2 keys, OAuth client secrets, and keystores do not belong in this README or Git. Keep account recovery methods current and enable multi-factor authentication. The Firebase project ID is `bussinessfinder-327f5`.

## What is in this repository

- Flutter application code: `lib/`
- Firebase client options: `lib/firebase_options.dart`
- Firestore rules: `firestore.rules`
- Realtime Database rules: `database.rules.json`
- Cloud Functions (Node.js 22): `functions/` (`index.js` media/push/admin, `social.js` likes/comments/notifications, `feed.js` feeds/search, `ghost.js` ghost archive, `shop.js` + `payments/` shop and payments, `status.js` 24h statuses, `account.js` account deletion, `moderation.js` report alerts, `admin.js` Admin panel actions, `scripts/` owner tools)
- Translations: `lib/core/i18n/` (`tr()` + `rw_strings.dart`); test: `test/translations_test.dart`
- Release: `docs/`, `tools/`, `site/` (public legal pages), `store-assets/` (Play icon + feature graphic)
- Deploy script: `deploy.ps1`; security-rules tests: `rules-tests/`
- Android app: `android/`
- Windows desktop runner and Inno Setup installer: `windows/`
- R2 configuration guide: [`R2_SETUP.md`](R2_SETUP.md)
- App image assets and logo: `assets/`

The main app includes email/password, Google and phone authentication; profile completion; creator/business pages; For You, Following and Reels feeds; posts with photos/videos; chat requests and chats; voice/video calls; notifications; and privacy/ghost-mode controls.

There are currently **no separate Flutter dev/staging/production flavors or Firebase option sets**. Debug and release builds use the same Firebase project configuration unless you deliberately change it. That means development runs can write to the current Firebase project. Create and configure a separate staging project before inviting testers or using production data for development.

### Current service architecture

- **Firebase Authentication:** email/password with email verification, Google sign-in, and SMS phone verification.
- **Cloud Firestore:** user profiles, posts, business pages, chats/messages, notifications, follows, call signaling, and other app data. Firestore rules are in `firestore.rules`.
- **Firebase Realtime Database:** online presence (`status/{uid}`) and typing indicators (`typing/{chatId}/{uid}`); rules are in `database.rules.json`.
- **Firebase Cloud Messaging (FCM):** Android push notifications. Functions send push notifications from Firestore notification/call events. Windows has desktop-specific notification handling; do not assume Android background delivery behavior is identical on Windows.
- **Cloud Functions:** Node.js 22, deployed in `us-central1` unless an export specifies otherwise. Functions require Firebase billing (Blaze) for the current project setup and incur usage charges.
- **Cloudflare R2:** public profile/business/post media and private chat attachments use separate buckets. Firebase Auth remains the identity source; Firestore remains the application database. See `R2_SETUP.md`.
- **Windows Google OAuth:** the Windows sign-in flow reads `WINDOWS_GOOGLE_CLIENT_ID` and `WINDOWS_GOOGLE_CLIENT_SECRET` from Dart defines. The local file `windows_google_oauth.json` is ignored by Git.

## Development environment

Install and verify:

1. Flutter stable, Dart (bundled with Flutter), and Git.
2. Android Studio or Android SDK command-line tools for Android development. Accept Android SDK licenses and install the SDK/platform tools needed by the Flutter version in use.
3. A JDK compatible with the Android Gradle Plugin. This project compiles Android code with Java 17. Android Studio's bundled JDK is usually suitable.
4. For Windows desktop: Windows 10/11 x64, Visual Studio 2022 or Build Tools with **Desktop development with C++**, CMake, and Ninja. Inno Setup 6 is needed only to build the Windows installer.
5. Node.js 22 and Firebase CLI for Cloud Functions and Firebase deployments.

The current workstation reports Flutter **3.38.1** with Dart **3.10.0**. Confirm with `flutter --version`; use this version or a compatible Flutter stable release when setting up another machine. Do not upgrade Flutter and Android/Windows native build tools at the same time as a release change without rebuilding both platforms.

Check the workstation:

```powershell
flutter doctor -v
flutter devices
flutter emulators
node --version
firebase --version
```

Use `flutter doctor -v` to resolve local SDK/toolchain issues. The Android build downloads Gradle and native/plugin dependencies on the first build; allow that build to finish and keep a stable network connection. Do not delete `build/` or Gradle caches just because the first compile is slow.

## Local setup

From the repository root:

```powershell
flutter pub get
```

### Firebase client configuration

The current Firebase project is `bussinessfinder-327f5`. `lib/firebase_options.dart` has the client options used by Flutter; Android also loads `android/app/google-services.json` through the Google Services Gradle plugin.

If setting up a clean checkout or a different Firebase project:

1. In Firebase Console, create/register the platform apps for the intended Firebase project.
2. Configure Email/Password, Google, and Phone providers under **Authentication → Sign-in method**. Configure authorized domains and OAuth consent details as required by Google.
3. Download that Firebase Android app's `google-services.json` into `android/app/` (not merely the repository root).
4. Run FlutterFire CLI configuration if the Firebase project/app IDs change, then inspect `lib/firebase_options.dart` and commit only the intended client configuration.
5. Add SHA-1 and SHA-256 fingerprints for every Android signing certificate in Firebase Console. Debug and release/upload certificates are different. Re-download `google-services.json` after registering a new Android app or changing Firebase app configuration.
6. Confirm the Firebase project selected by `.firebaserc` before any deploy command.

Firebase client API keys are identifiers, not server credentials. Restrict Google Maps and other Google API keys by Android package name, signing certificate, and enabled APIs; never treat a mobile API key as a secret. The current Android manifest contains a Maps API key, so it must be reviewed and restricted before release.

### Windows Google sign-in configuration

The local config file is expected at the project root as `windows_google_oauth.json` and must match this shape:

```json
{
  "WINDOWS_GOOGLE_CLIENT_ID": "your-desktop-oauth-client-id.apps.googleusercontent.com",
  "WINDOWS_GOOGLE_CLIENT_SECRET": "your-desktop-oauth-client-secret"
}
```

Run the Windows app with:

```powershell
flutter run -d windows --no-pub --dart-define-from-file=windows_google_oauth.json
```

The desktop OAuth flow listens on loopback port `8000`; configure the matching OAuth client/redirect setup in Google Cloud Console and keep the port available. `windows_google_oauth.json` and `client_secret_*.json` are ignored by Git. Never commit them. Dart defines are compiled into the application, so do not assume values embedded in a distributed desktop binary are confidential. Before distributing Windows builds, verify the OAuth client type and flow against Google's current installed-app guidance and avoid embedding any credential that grants server/API access.

### Cloudflare R2 and Firebase Functions

Follow [`R2_SETUP.md`](R2_SETUP.md) to create the public/private buckets, configure a public media domain, and save R2 credentials as Firebase Functions secrets. The app expects these Functions environment values (in the ignored `functions/.env.bussinessfinder-327f5` file):

```dotenv
R2_ACCOUNT_ID=your_cloudflare_account_id
R2_PUBLIC_BUCKET_NAME=bussinessfinder-public
R2_PRIVATE_BUCKET_NAME=bussinessfinder-private
R2_PUBLIC_BASE_URL=https://your-public-media-domain
```

The expected secret names are `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`; set them through Firebase's secret prompt, not by putting their values in a tracked file:

```powershell
firebase functions:secrets:set R2_ACCESS_KEY_ID --project bussinessfinder-327f5
firebase functions:secrets:set R2_SECRET_ACCESS_KEY --project bussinessfinder-327f5
```

Media uploads are limited to 250 MB in the current client and Functions. Chat media uses the private bucket and chat membership checks; do not enable public access or an `r2.dev` URL for the private bucket. Public media URLs are intended for profile/business/post media. Monitor R2 operations, storage and egress, and set billing alerts for Google Cloud/Firebase.

## Run in development mode

### Android emulator

Start an Android emulator in Android Studio or with `flutter emulators --launch <emulator-id>`, then check the device ID:

```powershell
flutter devices
flutter run -d emulator-5554 --no-pub
```

Replace `emulator-5554` with the ID returned by `flutter devices`. `--no-pub` skips dependency resolution; use `flutter pub get` first after changing `pubspec.yaml` or when the package cache is missing.

### Windows desktop

```powershell
flutter run -d windows --no-pub --dart-define-from-file=windows_google_oauth.json
```

The OAuth file is only needed for Windows Google sign-in. If testing other functionality without it, omit the dart-define option; Google sign-in will report that desktop OAuth is not configured.

### Useful development commands

```powershell
flutter analyze
flutter test
flutter clean
flutter pub get
```

`flutter clean` removes generated build output and causes the next native build to do more work. Run it for stale/corrupt build artifacts, not as a routine performance fix. Keep Flutter, Dart, Gradle, Android Gradle Plugin, Kotlin and plugin versions aligned; change them deliberately and verify both Android and Windows.

## Firebase deployment

Use `deploy.ps1` (see **Deploying** at the top). It signs in, deploys only what changed, and avoids the CPU quota problem. Before the first deploy, confirm the project:

```powershell
firebase login
firebase use bussinessfinder-327f5
```

Manual commands, if you ever need them:

```powershell
firebase deploy --only firestore:rules,firestore:indexes,database --project bussinessfinder-327f5
firebase deploy --only functions:createOrder,functions:onOrderWritten --project bussinessfinder-327f5
```

Avoid `firebase deploy --only functions` with no names: it updates all ~32 functions at once and hits the CPU quota. Firebase does not let a deployed function change trigger type under the same name; deploy a new name, move callers, then delete the old one. Never deploy test rules that allow unrestricted reads/writes.

## Build artifacts

### Android (Google Play): see docs/RELEASE.md

Everything for Android releases is in **[docs/RELEASE.md](docs/RELEASE.md)**:
upload key, app id `rw.duhuze.app`, `tools/build-release.ps1` (App Bundle +
APKs + debug symbols), Play Console, closed testing and production rollout.
Store texts and form answers: [docs/PLAY_LISTING.md](docs/PLAY_LISTING.md).

Quick development APK (debug-signed, for your own phone only):

```powershell
flutter build apk --release
```

### Windows (desktop) app

Same Firebase project, same accounts and data as Android. Run it while developing:

```powershell
flutter run -d windows --dart-define-from-file=windows_google_oauth.json
```

Make the installer for other PCs (needs **Inno Setup 6**: https://jrsoftware.org/isdl.php):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\installer\build_installer.ps1
```

- Output: `build\windows\installer-output\Duhuze-Setup-<version>-x64.exe`. The version comes from `pubspec.yaml`, the same as Android (`tools\build-release.ps1 -NextBuild` raises it).
- `windows_google_oauth.json` (not in Git) holds the Windows Google sign-in client; the script uses it automatically.
- Publisher: **DUHUZE TECHS** (`windows/installer/Duhuze.iss`, `windows/runner/Runner.rc`). The Windows notification id is `DuhuzeTechs.Duhuze` (app and installer shortcuts must match). It must stay **longer than 16 characters**: win_toast 0.4.0 crashes on shorter ids.
- Before giving the installer to many people, sign `Duhuze.exe` and the setup with a code-signing certificate. Unsigned apps get a SmartScreen "unknown publisher" warning.

**What works differently on Windows** (kept on purpose):

| Feature | Windows | Why |
| --- | --- | --- |
| Online / typing | Works, through the Realtime Database REST API (`lib/features/chat/data/rtdb_rest.dart`). Desktop sends "online" every minute; a desktop quiet for 3 minutes shows offline; closing the window shows offline at once. | The `firebase_database` plugin has no Windows version. |
| Push notifications | Windows toasts while the app is open (it listens to `notifications`). Nothing arrives when Duhuze is closed. | Firebase Cloud Messaging does not support Windows. |
| Camera (take photo / record video) | Hidden. Pick files from the PC instead. | `image_picker` has no camera on Windows. |
| Video | Plays with `media_kit` (feed, reels, status). Uploaded as-is, without compression. | `video_player`/`video_compress` have no Windows version. |
| MoMo Pay | "Pay from your phone": shows the USSD code to dial on your MTN phone, then asks "Did the payment go through?" | A PC cannot dial USSD. |
| Live location | Works while the app is open, using Windows Location (Settings → Privacy → Location must be on). Accuracy is Wi-Fi based. | No GPS on most PCs; no background mode. |
| Status viewer | Arrow keys = next/back, Space = pause, Esc = close. | Desktop keyboard. |
| Picking files | Always through `MediaPicker` (`lib/core/services/media_picker.dart`): the Windows file window opens from a background worker, and big photos are shrunk in the background. Don't call `ImagePicker()` directly: on Windows it freezes the app while Explorer loads. | `image_picker` opens the dialog on the app's main thread. |
| Video thumbnails | Taken from the video with a hidden, muted media_kit player, one at a time, cached on disk (`lib/core/services/video_frame_grabber.dart`). | `video_thumbnail` has no Windows version. |
| Layout | Side menu (For You / Reels / Following, Discover, Messages, Notifications, Saved, Shop, Profile, Settings). Right panel from 1180 px; wide menu from 1440 px. Window can't go below 760×600. Shortcuts: `1/2/3`, `Ctrl+N/K/M`, `F5`, `Home`, arrows. | Desktop screens and small laptops. |

## Troubleshooting notes

- **Android Google sign-in fails:** confirm the registered Firebase Android app matches `applicationId`, add the signing certificate SHA-1/SHA-256 (debug or release/Play app-signing as applicable), enable Google provider, and replace `google-services.json` with the matching file.
- **Windows Google sign-in opens browser but does not return:** check the desktop OAuth client, `windows_google_oauth.json`, callback port 8000 availability and the redirect setup in Google Cloud Console.
- **R2 upload returns 403:** verify the bucket/token scope, R2 account ID, Functions secrets, `.env` parameter names, deployed Function region/project, allowed MIME type, upload size, and that the generated URL's headers match the signed content type. Never put R2 keys in Flutter config.
- **Firebase Functions deployment reports a trigger mismatch:** a deployed function cannot always change trigger type in place. Inspect the deployed function, deploy under a new name if needed, switch callers/triggers, and only then remove the obsolete function.
- **Windows CMake/Visual C++ errors:** install/repair Visual Studio 2022 Desktop C++ tools and CMake/Ninja; after a confirmed stale generated build, `flutter clean` and rebuild.
- **Android build is very slow:** the first Gradle/native dependency build is expensive. Keep the emulator/device connected and run `flutter run -d <device-id> --no-pub` after dependencies are resolved.

## Security and maintenance rules

- Never commit `windows_google_oauth.json`, `client_secret_*.json`, Firebase service-account JSON, R2 credentials, release keystores, passwords, or private signing material. Check `.gitignore` before adding any configuration file.
- The included `google-services.json` and `lib/firebase_options.dart` are client configuration, not authorization controls. Access control must come from server-side Firebase rules and authenticated Functions.
- Avoid sharing complete logs/screenshots that include OAuth tokens, phone numbers, email addresses, signed media URLs or personal data.
- Use least-privilege R2 tokens scoped to the app's buckets. Rotate exposed credentials immediately and update Firebase secrets.
- Keep owner access safe: Cloudflare account `batman006rtz@gmail.com`; Firebase account `nelsonjembe99@gmail.com`. Do not put passwords or MFA recovery codes here.
- Keep dependency lockfiles under source control. Review Flutter/plugin/Node updates and Firebase/Play policies before release changes.

## Important configuration values (non-secret)

| Setting | Current development value |
| --- | --- |
| Firebase project ID | `bussinessfinder-327f5` |
| Cloud Functions region | `us-central1` |
| Android application ID | `rw.duhuze.app` once `tools/register-android-app.ps1` has run; until then builds use `com.example.bussinessfinder` |
| Android/Flutter version | `1.0.0+1` |
| Cloud Functions Node runtime | `22` |
| Maximum media upload size | `250 MB` |
| Windows OAuth callback port | `8000` |

---

Private project. No open-source license is declared.
