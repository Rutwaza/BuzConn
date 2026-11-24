# Releasing Duhuze on Google Play

Step by step, from this repository to the app in the Play Store. Do the steps
in order; each one says what you need, what to run and how to know it worked.

| Doc | What it is for |
| --- | --- |
| **docs/RELEASE.md** (this file) | The release process, first time and every update |
| [docs/PLAY_LISTING.md](PLAY_LISTING.md) | Texts, images and the answers for every Play Console form |
| [docs/TESTING.md](TESTING.md) | What to test on phones before each release |
| [docs/MODERATION.md](MODERATION.md) | Handling reports, blocks, child-safety cases, the ghost archive |
| [README.md](../README.md) | Handbook: project state, deploying, data map, critical notes |

**Timeline for the first release with a new personal Play account:** about
3–4 weeks. Google requires a closed test with at least 12 testers who stay
opted in for 14 days in a row before you can publish to everyone. An
organization account skips that, but needs a D-U-N-S number for a registered
company.

---

## 0. Tools on your PC (once)

| Tool | Check it works |
| --- | --- |
| Flutter (stable) | `flutter doctor` shows no red X for Android |
| Android Studio (includes Java/keytool and the Android SDK; install SDK Platform **36**) | `flutter doctor --android-licenses` accepted |
| Node.js 22 + Firebase CLI | `firebase --version` |
| Git | `git status` in the project folder |

Every command below runs from the project folder:
`C:\Users\Nexon\Desktop\PROJECTS\BussFinder\bussinessfinder`

---

## 1. Before every release: the checklist

- [ ] **Phones tested** with [docs/TESTING.md](TESTING.md). No crash, no red error screens.
- [ ] **Backend is up to date:** `.\deploy.ps1 -DryRun` says *Nothing to deploy*. If not, run `.\deploy.ps1`.
- [ ] **Rules tests pass:** `cd rules-tests; npm test` (needs Java).
- [ ] **Translations:** `flutter test test/translations_test.dart`. New texts without Kinyarwanda are listed there.
- [ ] **Version number** goes up (step 5 does it for you).

First release only:

- [ ] Website pages are live (step 2).
- [ ] Upload key made and backed up (step 3).
- [ ] App id `rw.duhuze.app` registered (step 4).
- [ ] Admin claim set and the email fallback removed (README → *Other things that must not be forgotten*).
- [ ] A native Kinyarwanda speaker has read `lib/core/i18n/rw_strings.dart`. Translations were drafted with AI help.
- [ ] Privacy policy checked by someone who knows Rwanda's data protection law. **Register with NCSA** (National Cyber Security Authority) as a data controller: the law requires registration, and storing data outside Rwanda (Google, Cloudflare) needs their authorization.
- [ ] Map tiles: switch `AppConstants.mapTileUrl` to a paid provider if you expect many users.
- [ ] MoMo USSD format checked on a real MTN line (`AppConstants.momoPayUssd`).

---

## 2. Publish the website (privacy, terms, account deletion, child safety)

Google Play needs public links to these pages. They are in `site/` and are
hosted free on Firebase Hosting.

1. Open every file in `site/` and replace:
   - `CHANGE_ME_EMAIL` → the support email people should write to. A dedicated address like `support@…` is best, not your personal Gmail.
   - `CHANGE_ME_OWNER` → your full name, or your company name if you have one.
2. Read `site/privacy.html` once, completely. It must match what the app does.
3. Run `.\deploy.ps1`. It refuses to publish the website while any `CHANGE_ME` is left.
4. Check in a browser:
   - https://duhuze.web.app/privacy
   - https://duhuze.web.app/terms
   - https://duhuze.web.app/delete-account
   - https://duhuze.web.app/child-safety

The app links to these pages from Settings and the sign-up screen
(`AppConstants.websiteUrl`). If you later buy a domain (e.g. duhuze.rw),
connect it in Firebase Hosting and change `websiteUrl`.

---

## 3. Make the upload key (once, ever)

Google Play only accepts files signed with *your* key.

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\create-upload-key.ps1
```

- It asks for a password, makes `%USERPROFILE%\duhuze-keys\duhuze-upload.jks`
  and writes `android\key.properties`. That file is in `.gitignore`; never commit it.
- **Back up** the `.jks` file and the password now: a USB stick plus a password
  manager. Google keeps the real *app signing key* (Play App Signing), so a lost
  upload key can be reset through Play support, but it takes days.

---

## 4. Register the final app id `rw.duhuze.app` (once)

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\register-android-app.ps1
```

What it does:
1. Creates the Android app `rw.duhuze.app` in Firebase project `bussinessfinder-327f5`.
2. Adds the SHA-1/SHA-256 fingerprints of your debug key and upload key. Google sign-in and phone sign-in need these.
3. Downloads the new `android\app\google-services.json`. The old one is kept as `.bak`.

From now on builds use `rw.duhuze.app`. Before this step, `build.gradle.kts`
keeps the old id, so nothing breaks.

> Test on a phone after this step: Google sign-in and phone (SMS) sign-in. If
> Google sign-in fails with "developer error", the fingerprint is missing:
> run the script again after one `flutter run`.

---

## 5. Build the release files

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\build-release.ps1 -NextBuild -Apk
```

- `-NextBuild` raises the build number in `pubspec.yaml` (`1.0.0+1` → `1.0.0+2`).
  **Google refuses an upload whose build number was used before.**
- `-Version 1.1.0` sets a new visible version, also raising the build number.
- `-Apk` also makes installable APKs to send to testers by WhatsApp or USB.

Output in `release\<version>-<build>\`:

| File | Use |
| --- | --- |
| `duhuze-1.0.0-2.aab` | **Upload this to Google Play** |
| `duhuze-1.0.0-2-arm64-v8a-release.apk` | Install on most modern phones for testing |
| `debug-info-1.0.0-2.zip` | **Keep it.** Needed to read crash reports (the code is obfuscated) |

Then save the version change: `git commit -am "Release 1.0.0+2"`.

---

## 6. Google Play developer account (once)

1. Go to https://play.google.com/console and sign up with the Google account that will own Duhuze.
2. Choose the account type:
   - **Personal**: quick, but you must run the 12-testers / 14-days closed test before going public.
   - **Organization**: needs a registered company and a D-U-N-S number (free, can take weeks). No 12-tester rule.
3. Pay the one-time registration fee and complete identity verification. Use the name and address on your ID.
4. Verify the contact phone number and email that Google asks for.

---

## 7. Create the app and upload the first build

1. Play Console → **Create app**:
   - App name **Duhuze**
   - Default language English (add Kinyarwanda later in the store listing)
   - App, Free
   - Accept the declarations
2. **Play App Signing:** keep Google's default ("Google generates and protects the app signing key").
3. Fill the **App content** forms and the **Store listing**. Every answer is in [docs/PLAY_LISTING.md](PLAY_LISTING.md).
4. **Internal testing** (instant, up to 100 people, good for you and close friends):
   Testing → Internal testing → Create release → upload the `.aab` → release notes → Save → Review → Roll out.
5. **After the first upload, add Play's signing key to Firebase.** Otherwise Google sign-in fails for everyone who installs from Play:
   - Play Console → Test and release → App integrity → App signing → copy **SHA-1** and **SHA-256** of the *App signing key certificate*.
   - Run:
     ```powershell
     powershell -ExecutionPolicy Bypass -File .\tools\register-android-app.ps1 -PlaySigningSha1 AA:BB:... -PlaySigningSha256 11:22:...
     ```

---

## 8. Closed test: 12 testers for 14 days (personal accounts)

1. Make a Google Group (e.g. `duhuze-testers@googlegroups.com`) and add at least **15–20** testers. Some always drop out; 12 must stay the whole time.
2. Testing → Closed testing → Create track → Testers → add the Google Group → upload the same `.aab` (or a newer build) → roll out.
3. Send testers the **opt-in link** from the Testers tab. Each tester must open it, tap *Become a tester*, then install from Play.
4. Keep them **opted in for 14 days in a row**. Ask them to really use the app and to send feedback. Fix bugs and upload new builds to the same track; that does not restart the clock.
5. After 14 days: Dashboard → **Apply for production**. Answer the questions about how you tested. The review usually takes a few days.

---

## 9. Production release

1. Testing → Production → Create release → choose the tested build → release notes.
2. Countries: start with Rwanda (+ neighbours if you like). You can add more later.
3. **Staged rollout:** start at 20%, watch Android vitals and crashes for 1–2 days, then 50%, then 100%.
4. After it goes live, the store page is `https://play.google.com/store/apps/details?id=rw.duhuze.app`. Put that link on `site/index.html` and deploy.

---

## 10. Every update after that

1. Change code, commit, test on phones ([TESTING.md](TESTING.md)).
2. `.\deploy.ps1` if Firebase rules or functions changed. **Deploy the backend before the app update reaches people**, because the new app may need the new functions.
3. `.\tools\build-release.ps1 -NextBuild` (or `-Version 1.1.0` for a feature release).
4. Upload to Internal testing first, then promote to Production with a staged rollout.
5. Keep `release\…\debug-info-*.zip` for every version.

## When something goes wrong

| Problem | Fix |
| --- | --- |
| Play: "version code already used" | Run the build again with `-NextBuild` |
| Play: "must target API level 36" | `build.gradle.kts` already forces 36. Update Flutter and Android SDK Platform 36 |
| Play: "uploaded with the wrong key" | `android\key.properties` is missing or points to another key. Use the backed-up `.jks` |
| Google sign-in works in debug but not from Play | Step 7.5 (Play signing SHA-1 in Firebase) |
| Play rejects permissions (photos, location) | See the *Permissions* section of [PLAY_LISTING.md](PLAY_LISTING.md) |
| Crash with obfuscated stack trace | `flutter symbolize -i <trace.txt> -d <unzipped debug-info>/app.android-arm64.symbols` |
