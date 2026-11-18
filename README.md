# SpotLight

SpotLight is a Flutter social app for discovering creators and businesses, publishing image/video posts, and communicating through direct or business chats. Firebase provides identity, application data, realtime updates and push notifications. Cloudflare R2 stores media; authenticated Firebase Functions issue short-lived upload/download links.

This README is the setup and release handoff for the current repository. It describes the configuration found in this checkout, including gaps that must be closed before a public release. Do not treat a successful debug run as a production readiness check.

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
- Cloud Functions (Node.js 22): `functions/`
- Android app: `android/`
- Windows desktop runner and Inno Setup installer: `windows/`
- R2 configuration guide: [`R2_SETUP.md`](R2_SETUP.md)
- App image assets and logo: `assets/`

The main app includes email/password, Google and phone authentication; profile completion; creator/business pages; For You, Following and Reels feeds; posts with photos/videos; chat requests and chats; voice/video calls; notifications; and privacy/ghost-mode controls. The Functions source also contains existing bus, booking/card and agency-management endpoints. Review the complete exports in `functions/index.js` before deploying or granting production access; a full Functions deployment affects all exported functions, not only media and notifications.

There are currently **no separate Flutter dev/staging/production flavors or Firebase option sets**. Debug and release builds use the same Firebase project configuration unless you deliberately change it. That means development runs can write to the current Firebase project. Create and configure a separate staging project before inviting testers or using production data for development.

### Current service architecture

- **Firebase Authentication:** email/password with email verification, Google sign-in, and SMS phone verification.
- **Cloud Firestore:** user profiles, posts, business pages, chats/messages, notifications, follows, call signaling, and other app data. Firestore rules are in `firestore.rules`.
- **Firebase Realtime Database:** device/bus live data; rules are in `database.rules.json`.
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

Install the Firebase CLI and authenticate with the Firebase owner/deployment account. Confirm project selection before deploying:

```powershell
firebase login
firebase projects:list
firebase use bussinessfinder-327f5
```

Deploy rules separately when appropriate:

```powershell
firebase deploy --only firestore:rules,database --project bussinessfinder-327f5
```

Deploy only the media functions after R2 configuration is complete:

```powershell
firebase deploy --only functions:createR2UploadUrl,functions:createR2DownloadUrl --project bussinessfinder-327f5
```

Push/call notification functions currently include `sendNotificationDocumentPush` and `sendIncomingCallPush`; inspect the exports in `functions/index.js` and Firebase Console before changing/deleting deployed functions. Firebase does not permit changing a deployed function from one trigger type to another under the same name; a trigger change may require deploying a new name and deliberately migrating/deleting the old function.

For a full Functions deployment, install dependencies and inspect all exports first:

```powershell
Set-Location functions
npm ci
Set-Location ..
firebase deploy --only functions --project bussinessfinder-327f5
```

The full source also contains non-social bus/booking/card/agency endpoints. Do not run a full deployment without reviewing which functions will be updated, created or removed. Use a separate Firebase staging project for risky rules or backend changes. Never deploy test rules that allow unrestricted reads/writes.

## Build artifacts

### Android development APK

```powershell
flutter build apk --debug --no-pub
```

Output: `build/app/outputs/flutter-apk/app-debug.apk`.

### Android release App Bundle

```powershell
flutter build appbundle --release
```

Output: `build/app/outputs/bundle/release/app-release.aab`.

**Do not upload a release artifact from this checkout yet.** `android/app/build.gradle.kts` currently assigns the debug signing config to release builds, and the application ID is the development ID `com.example.bussinessfinder`. Set up a dedicated upload keystore and release signing configuration first (instructions below).

### Windows release and installer

Build the Windows app:

```powershell
flutter build windows --release --dart-define-from-file=windows_google_oauth.json
```

Build the installer with Inno Setup 6 installed:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\installer\build_installer.ps1
```

The installer script runs a Windows release build and produces `build/windows/installer-output/SpotLight-Setup-1.0.0-x64.exe`. If `windows_google_oauth.json` exists, it supplies the Windows OAuth Dart defines to that build. Update the version in `windows/installer/Spotlight.iss` when making a new installer. This is a Windows x64 setup executable containing the app and runtime files; it installs multiple files on the friend's PC. Sign the app and installer with a trusted code-signing certificate before broad distribution to reduce SmartScreen warnings. Windows OAuth review still applies.

## Production readiness checklist

The following items are **not all complete in the current checkout**. Finish and verify them on a staging project and release-signed builds before production:

### 1. Create a production identity

- Choose the final, globally unique Android application ID (for example, a domain you control in reverse-DNS form). Current value is `com.example.bussinessfinder` and is a placeholder.
- Update `applicationId`, `namespace`, the Kotlin package declaration/path for `MainActivity`, and any Android manifest/provider references together.
- Register a new Android app under the production Firebase project using that exact ID. Add the final package/SHA certificates to Firebase Auth/Google Sign-In and Maps key restrictions; download the matching `google-services.json`.
- The app ID can change before first Play publication. Once published, changing it creates a different Play app; users cannot update the original listing with a changed ID. Treat the chosen ID as permanent.
- Keep development, staging and production Firebase projects separate. Do not let debug/dev builds write to production data.

### 2. Configure release signing and versioning

- Generate a dedicated upload keystore and store it outside source control with a secure backup. Never lose it or share its passwords.
- Create an ignored `android/key.properties` with the keystore path, alias, and passwords. Add a release `signingConfig` that reads this file; remove the current debug signing config from `release`.
- Register the upload certificate's SHA-1/SHA-256 in Firebase for Google sign-in. Play App Signing has a separate app-signing certificate: add that SHA certificate in Firebase too after Play Console creates it, otherwise Google sign-in can fail for Play-installed builds.
- Enable Play App Signing and upload an AAB signed with the upload key.
- Increment `version:` in `pubspec.yaml` for every Play release (`versionName+versionCode`); current value is `1.0.0+1`.
- Build a signed AAB and install/test the corresponding Play internal/closed-test build. Debug builds do not prove release signing, auth fingerprints, permissions or notification behavior.

### 3. Firebase, Functions and Cloudflare production setup

- Configure Firebase Auth providers, email verification/reset templates, SMS regions/quotas, Google OAuth consent, authorized domains and abuse protections.
- Deploy and review Firestore/Realtime Database rules. Verify a user cannot read or change another user's private profile, chat, calls, notifications or private media. The rules file is security-critical; have it reviewed and test both allowed and denied cases.
- Deploy Functions from Node.js 22 sources; verify Functions secrets and R2 environment parameters in the production project. Confirm billing is active and configure budget alerts/monitoring. Budget alerts notify; they do not necessarily cap spending.
- Verify private chat media downloads require chat membership and the private bucket has no public endpoint. Verify public media domain, CORS behavior if any web clients are later added, limits, deletion/retention and backups.
- Check FCM on release-signed Android devices while app is foregrounded, backgrounded and force-stopped. Verify call/message notification content and deep links.
- Restrict the Android Maps API key by final app ID and Play signing certificate. Rotate keys if they have ever been exposed or used without restrictions.
- Configure logging/alerts and an incident response path. Review Firestore read/write volume, Function invocations, Cloud Build/Artifact Registry, R2 storage/operations and data egress costs.

### 4. Account deletion and user data (release blocker)

The current in-app delete action is incomplete for public release. It reauthenticates with an email/password credential, removes a subset of Firestore documents, then deletes the Firebase Auth user. It does **not** currently provide an external deletion request webpage, support every sign-in provider, or comprehensively remove related chat histories, R2 objects and all linked data. Partial cleanup can occur if deletion fails midway.

Before Play submission, implement and verify a complete deletion workflow that:

- Is discoverable inside the app and through a public web URL entered in Play Console.
- Reauthenticates appropriately for email, Google and phone accounts.
- Deletes or safely anonymizes all associated data and R2 files according to the stated retention policy, including shared-data decisions for other chat participants.
- Handles retries and partial failures safely, and gives the user a clear completion/status message.
- Is accurately disclosed in the privacy policy and Play Data safety/account deletion forms.

Google Play requires an in-app path and an external web resource for account deletion requests when users can create accounts. It requires deleting associated user data, subject only to clearly disclosed legitimate retention. See the official [account deletion requirement](https://support.google.com/googleplay/android-developer/answer/13327111) and [User Data policy](https://support.google.com/googleplay/android-developer/answer/10144311).

### 5. Privacy, safety and product compliance

- Publish a privacy policy on a stable public URL and link it from both the app and Play Console. It must describe Firebase, Cloudflare R2, authentication, profile content, location use, messages/media, notifications/device tokens, retention, deletion, contact details and any sharing/processors truthfully.
- Complete the Play Data safety form based on the real production SDKs and data flows; do not guess. Also complete app access instructions, ads declaration (if applicable), target audience/content, content rating, government/financial declarations if applicable, and reviewer credentials for gated parts of the app.
- SpotLight contains user-generated posts, profile content and chat. Add and operate appropriate reporting/blocking/moderation processes, terms/community rules and a support contact before opening it to the public.
- Explain and request camera, microphone, media/files, notifications, and location permissions only when the relevant feature is used. Check current Android permission behavior on supported OS versions.
- Confirm the app meets current target SDK requirements. As of **18 November 2026**, Google Play says new apps and updates must target Android 16 / API 36 or higher from 31 August 2026. Check the live [target API policy](https://support.google.com/googleplay/android-developer/answer/11926878) before each submission because dates and requirements change.
- Confirm age/content rating and countries where SMS phone authentication, Maps, and R2 access work and are supported.

## Publish on Google Play: end-to-end outline

1. Create/verify the Play Console developer account and complete identity/payment profile requirements.
2. Pick the permanent Android package ID; create the matching production Firebase Android app and OAuth/Maps setup.
3. Finish release signing and Play App Signing; safely back up the upload key. Google Play signs user-delivered APKs when Play App Signing is configured. See [Android app signing](https://developer.android.com/studio/publish/app-signing).
4. Finish the account deletion blocker, privacy policy, terms, moderation/reporting, data retention and production Firebase/R2 setup.
5. Set final app name, launcher icon, version number, screenshots, feature graphic, short/full description, support email, website and required region listings.
6. Build and inspect a signed release AAB:

   ```powershell
   flutter clean
   flutter pub get
   flutter build appbundle --release
   ```

   Confirm `build/app/outputs/bundle/release/app-release.aab` is signed with the upload key, targets the currently required API, has the final application ID, and uses production—not development—services.

7. Create the app in Play Console. Complete App content and Data safety, provide privacy/account-deletion URLs and test access instructions, then upload the AAB to Internal testing.
8. Test real devices for sign-up/login, email verification/reset, phone OTP, Google sign-in, profile completion, feeds/video, upload/download (including private media), chat requests, calls, push notifications, account deletion, upgrade/install behavior, performance and crash reporting.
9. Address Play pre-launch report and policy warnings. Run closed testing and collect feedback.
10. If the Play Console account is a **personal developer account created after 13 November 2023**, the current requirement is at least 12 testers opted into a closed test continuously for 14 days, then an application for production access. Organization accounts and other account histories may differ; check the current [testing requirement](https://support.google.com/googleplay/android-developer/answer/14151465).
11. Submit the production release for review and roll out gradually. Watch crashes, ANRs, sign-in, Functions/R2 billing and user support after launch.

For a first Play release, the official Android guidance recommends an Android App Bundle and Play App Signing. Read the current [upload bundle guide](https://developer.android.com/studio/publish/upload-bundle) and Play Console instructions at release time.

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
| Android application ID | `com.example.bussinessfinder` (development placeholder; choose final ID before Play) |
| Android/Flutter version | `1.0.0+1` |
| Cloud Functions Node runtime | `22` |
| Maximum media upload size | `250 MB` |
| Windows OAuth callback port | `8000` |

---

Private project. No open-source license is declared.
