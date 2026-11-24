# Testing Duhuze on phones

Use **two Android phones** (or one phone + the Windows app) with **two
different accounts**, A and B. One phone on Wi-Fi, one on mobile data if
possible. Tick every line before a release. When something fails, write
down: phone model, Android version, what you did, what happened, and a
screenshot.

Run first: `flutter run --release` (or install the APK from
`tools\build-release.ps1 -Apk`). Debug builds are slower than real ones.

## 1. Accounts
- [ ] Sign up with email; verification email arrives; sign in.
- [ ] Sign in with Google.
- [ ] Sign in with phone number (SMS code arrives).
- [ ] Sign-up screen shows "By creating an account you agree to the Terms of use and the Privacy policy"; both links open.
- [ ] Forgot password email arrives.
- [ ] Complete profile, set username, change photo.

## 2. Feed, posts, reels
- [ ] Post a photo, several photos, a video (a long phone video is compressed before upload).
- [ ] For You, Following and Reels tabs load; scrolling loads more.
- [ ] Like / unlike: the count changes at once and stays after a restart.
- [ ] Comment, reply, like a comment, delete own comment.
- [ ] Reels: swiping to the next reel starts quickly (it was preloaded).
- [ ] Search finds a user, a page, a post by a word.

## 3. Status
- [ ] A posts a text status (change colour), a photo status, a video status.
- [ ] B (who follows A) sees A's ring at the top of the feed, teal; after watching it turns grey.
- [ ] Viewer: tap right/left, hold to pause, swipe down to close.
- [ ] A opens own status and sees "1" view and B in the list.
- [ ] A deletes a status.
- [ ] After 24 h the status is gone. You can check in Firestore → `statuses`: the hourly cleanup deletes it.

## 4. Chat
- [ ] A messages B: the message appears instantly; B gets a push notification.
- [ ] Typing indicator and online status.
- [ ] Photo, video, voice note, document.
- [ ] Voice call and video call (both directions); the ringtone stops when answered.
- [ ] Ghost mode: B reads a ghost message, it disappears for both. In Firestore → `ghost_archive` there is an encrypted copy.
- [ ] Clear chat (only for me).
- [ ] Message request from a stranger: approve / decline.

## 5. Location
- [ ] 📎 → Location → **Send my current location**: the bubble shows a map with A's photo pin.
- [ ] B opens it: full map, A's pin, B's blue "me" dot, distance, **Directions** opens Google Maps.
- [ ] **Share live location 15 min**: notification "Sharing live location" appears. Walk around: B sees the pin move (about every 15 s / 20 m).
- [ ] Press Home (app in the background), keep walking: the pin still moves.
- [ ] Stop sharing: B sees "Live location ended"; the notification disappears.
- [ ] Location off on the phone → a clear message, no crash.

## 6. Shop and MoMo
- [ ] A (business) → Edit page → MoMo Pay code + name → Save.
- [ ] A → My shop → add product (photo, price, in stock), edit, mark out of stock, delete.
- [ ] B → A's page → Shop → add 2 items → **Pay with MoMo**: dialer opens with `*182*8*1*CODE*AMOUNT#`.
  - [ ] **Check on a real MTN line** that MTN accepts this format and shows the right name and amount. If not, change `AppConstants.momoPayUssd` (README → Payments).
- [ ] Back in the app: "Did the payment go through?" → **Yes, I paid** (with transaction ID) → A gets a notification.
- [ ] A → Orders → My shop → **Received ✓** → B gets "confirmed".
- [ ] Also test **Not received** → B pays again → Received.
- [ ] B cancels an order.

## 7. Report and block
- [ ] B reports A's post (⋮ → Report post): the admin account gets a "New report" notification; Firestore → `reports` has it.
- [ ] Report with reason "Child safety": the notification says URGENT.
- [ ] B blocks A (profile ⋮ → Block): A's posts and statuses disappear for B.
- [ ] A tries to message B: it fails (blocked). B unblocks: it works again.

## 7b. Admin panel (admin account + a moderator account + a normal account)
- [ ] `node scripts/set-admin.js <your email>` → sign out/in → Settings shows **Admin panel**; a normal account does not see it.
- [ ] Reports tab: counts at the top; B's report of A's post is in **Open**; child safety reports are on top in red.
- [ ] Open the report: A's name, the post photo/text. **Dismiss** → moves to **Handled** with your note.
- [ ] New report → **Remove post**: the post disappears for everyone; Firestore `evidence/<reportId>` has a copy.
- [ ] **Suspend user** (use a test account): it is logged out within about an hour, and at once on the next sign-in try ("This account is suspended"). **Users** tab → Restore → it can sign in again.
- [ ] Team tab → Add moderator (email of a test account) → they sign out/in → they see **Moderator panel** with Reports + Users, no Team tab. Remove them → they lose access after signing in again.
- [ ] Firestore `admin_events` lists each action with your email.

## 8. Settings
- [ ] Language → Ikinyarwanda: all main screens change; back to English.
- [ ] Theme dark/light.
- [ ] Lite mode: set **On**. Feed videos show "Tap to play · Lite mode"; Reels still play. **Auto** on mobile data does the same.
- [ ] Privacy policy / Terms / Child safety links open the website.
- [ ] Notifications screen: likes, comments, follows, messages, orders open the right screen.

## 9. Delete account (use a throw-away account!)
- [ ] Email account: Settings → Delete Account → password → account gone, back to login, cannot sign in again.
- [ ] Google or phone account: if signed in more than 15 min ago, the app asks to sign out and in; then type DELETE → deleted.
- [ ] In Firestore: no `users/<uid>`, no posts, statuses or follows of that user. `admin_events` has `account_deleted`.

## 10. Slow network and offline
- [ ] Airplane mode: open chats, write a message: it appears with a pending state and is sent when back online.
- [ ] Slow 3G (Developer options → network speed or a weak area): the feed is still usable.

## 11. Release build only
- [ ] The app icon is the Duhuze icon; the app name is "Duhuze".
- [ ] After installing from Play (internal test): Google sign-in works (Play signing SHA-1 added: RELEASE.md step 7.5).
