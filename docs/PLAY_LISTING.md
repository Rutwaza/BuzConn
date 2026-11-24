# Google Play: store listing and App content answers

Copy-paste material for Play Console. Each answer matches what the code
actually does (November 2026). **If you add a feature that collects new data,
update this file, `site/privacy.html` and the Data safety form together.**

---

## Store listing

**App name** (max 30): `Duhuze: Africa Connected`

**Short description** (max 80):
`Reels, status, chat and local shops with MoMo. Connect with Rwanda and Africa.`

**Full description** (English):

```
Duhuze ("let's connect") brings people, creators and local businesses together.

• Feed & Reels: share photos and short videos, discover what's trending, follow creators and pages.
• Status: share moments that disappear after 24 hours.
• Chat: fast private messages, voice notes, photos, documents, voice and video calls.
• Ghost messages: messages that vanish from the chat after they are read.
• Share your location: send where you are, or share your live location with a friend for 15 minutes to 8 hours.
• Business pages & Shop: businesses list their products; buy with MTN MoMo Pay in a few taps.
• Kinyarwanda and English.
• Lite mode: saves your mobile data automatically.

Safety: report posts, users and chats, block anyone, and delete your account any time in Settings.

Duhuze: Africa Connected.
```

**Full description** (Kinyarwanda, add it as a translation; have a native speaker check it):

```
Duhuze ihuza abantu, abahanzi n'ubucuruzi bwo hafi yawe.

• Ibishya na Videwo ngufi: sangiza amafoto na videwo, reba ibigezweho, ukurikire abahanzi na paji.
• Status: sangiza ibihe bisibangana nyuma y'amasaha 24.
• Ibiganiro: ubutumwa bwihuse, amajwi, amafoto, inyandiko, guhamagara mu ijwi no kuri videwo.
• Ubutumwa bwa ghost: bubura mu kiganiro nyuma yo gusomwa.
• Sangiza aho uri: ohereza aho uri, cyangwa usangize aho uri uko ugenda mu minota 15 kugeza ku masaha 8.
• Paji z'ubucuruzi n'Iduka: gura ukoresheje MTN MoMo Pay mu buryo bworoshye.
• Ikinyarwanda n'Icyongereza.
• Lite mode: izigama interineti yawe.

Umutekano: menyesha ikibazo, hagarika uwo ushaka, kandi usibe konti yawe igihe cyose muri Igenamiterere.
```

**Category:** Social · **Tags:** Social networking, Messaging, Shopping
**Contact email:** the support email from `site/` · **Website:** https://duhuze-rw.web.app
**Privacy policy URL:** https://duhuze-rw.web.app/privacy

### Graphics

| Asset | File / how to make it |
| --- | --- |
| App icon 512×512 | `store-assets/play-icon-512.png` (ready) |
| Feature graphic 1024×500 | `store-assets/play-feature-graphic-1024x500.png` (ready) |
| Phone screenshots (2–8, at least 1080 px on the short side) | Take them on a phone with real-looking demo content: 1) feed with Status row, 2) Reels, 3) chat with a location bubble, 4) business Shop, 5) MoMo pay sheet, 6) Settings in Kinyarwanda. Never show real people's private chats. |

---

## App content forms (Play Console → Policy → App content)

### Privacy policy
`https://duhuze-rw.web.app/privacy`

### Ads
**No**, the app does not contain ads.

### App access
**Some functionality is restricted** (sign-in required). Give the reviewers a
working test account: email + password of an account you made for them, with
a few posts, a chat and a shop with one product. Note: "Phone sign-in also
available; use the email account to review."

### Content rating (IARC questionnaire)
- Category: **Social / Communication**.
- Users can interact and exchange content: **Yes** (chat, comments, posts).
- Shares user location with other users: **Yes**, only when the user chooses to share it in a chat.
- Allows purchases of physical goods: **Yes**, through the shops; payment happens outside the app with MTN MoMo.
- Violence, sexual content, drugs, gambling made by the developer: **No**. The content comes from users and is moderated by reports.
- Expect a **Teen / 12+ / PEGI 12** type rating because of user-generated content and chat.

### Target audience and content
- Age groups: **13–15, 16–17, 18+**. Do **not** include under 13.
- Appeal to children: **No**.

### Data safety

Data is **encrypted in transit**: Yes. Users can **request deletion**: Yes
(Settings → Delete Account, and https://duhuze-rw.web.app/delete-account).
Shared with third parties (in Google's meaning): **No**. Google Firebase and
Cloudflare are *service providers* processing data for us, which Google does
not count as sharing.

| Data type | Collected | Optional? | Purpose |
| --- | --- | --- | --- |
| Personal info → Name | Yes | Required | App functionality, Account management |
| Personal info → Email address | Yes | Optional (needed for email sign-in) | Account management |
| Personal info → Phone number | Yes | Optional (needed for phone sign-in) | Account management |
| Personal info → User IDs | Yes | Required | App functionality, Account management |
| Location → Precise location | Yes | Optional (only when you share it in chat; business address) | App functionality |
| Messages → Other in-app messages | Yes | Required for chat | App functionality |
| Photos and videos | Yes | Optional | App functionality |
| Audio → Voice or sound recordings | Yes | Optional (voice notes) | App functionality |
| Files and docs | Yes | Optional (documents in chat) | App functionality |
| Financial info → Purchase history | Yes | Optional (shop orders) | App functionality |
| App activity → App interactions (likes, follows, views) | Yes | Required | App functionality, Personalization (feeds) |
| App activity → Other user-generated content (posts, comments, status) | Yes | Optional | App functionality |
| Device or other IDs (push token) | Yes | Required | App functionality (notifications) |

Not collected: contacts, calendar, health, web history, payment card/bank
info (MoMo happens in MTN's own menu), advertising ID, crash logs/analytics.

### Account deletion
- In the app: **Yes**, Settings → Delete Account.
- Web link: `https://duhuze-rw.web.app/delete-account`

### Child safety standards (required for social apps)
- Standards URL: `https://duhuze-rw.web.app/child-safety`
- In-app reporting: Yes (Report → "Child safety").
- Child safety point of contact: your name and the support email.

### Government app / Financial features / Health
- Government app: No.
- Financial features: the app does **not** offer loans, banking, crypto or a
  wallet. If asked about payments: *"Shops show their MTN MoMo Pay merchant
  code; the buyer pays in MTN's own USSD menu. The app does not process or
  hold money."*
- Health: No.

### News app: No · COVID-19 app: No

---

## Permissions to explain

| Permission | Why (text for Play Console when asked) |
| --- | --- |
| `ACCESS_FINE_LOCATION` / `COARSE` | The user sends their location in a chat or shares live location with a friend; businesses pin their address. Only after a tap. |
| `FOREGROUND_SERVICE_LOCATION` | **Live location sharing**: after the user starts it in a chat, their position keeps updating for the time they chose (15 min–8 h) with a visible notification "Sharing live location", also when the app is in the background. They can stop it any time. Google asks for a **short video** showing this: record starting live location in a chat, the notification, and Stop. |
| `CAMERA`, `RECORD_AUDIO` | Photos/videos for posts and status, voice notes, voice and video calls. |
| `POST_NOTIFICATIONS` | Messages, calls, likes, comments, orders. |
| Photos and videos | No broad permission: the Android photo picker is used (`READ_MEDIA_IMAGES/VIDEO` were removed on purpose). |

---

## Release notes template

```
<en-GB>
What's new in Duhuze 1.0.0
• Status that disappears after 24 hours
• Share your (live) location in chat
• Shops: buy with MTN MoMo Pay
• Kinyarwanda language
• Lite mode to save data
</en-GB>
```
