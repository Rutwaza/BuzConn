# BuzConn (Business Connector)

BuzConn is a Flutter app that connects clients with local businesses. It includes business profiles, posts feed with media, in‑app chat (client↔business and client↔client), traffic management map, and a client search experience.

## Highlights
- Firebase Auth + Firestore
- Supabase Storage for media (images/videos)
- Business setup and management (logos, soft delete, restore)
- Posts feed with likes/comments, media, and business profiles
- Chat with replies, edits, deletes, read receipts, typing indicator
- Client profile page with top liked businesses
- Traffic management map (OSM/Carto)
- Notifications screen based on post interactions

## Tech Stack
- Flutter (Dart)
- Firebase: Auth, Firestore, Messaging
- Supabase Storage
- flutter_map (OSM/Carto tiles)

## Project Structure (key areas)
- `lib/presentation/pages/` UI pages
- `lib/data/repositories/` Firestore logic
- `lib/core/services/` Firebase/Supabase services
- `lib/core/routes/` GoRouter config

## Setup
1. **Install Flutter** (stable) and Android Studio or SDK tools.
2. **Firebase**
   - Add `google-services.json` to `android/app/`.
   - Make sure `lib/firebase_options.dart` matches your Firebase project.
3. **Supabase**
   - Set your Supabase URL and anon key in `lib/main.dart`.
   - Create buckets:
     - `profile-images`
     - `post-images`
     - `post-videos`
     - `chat-media`
   - Make buckets public or add RLS policies to allow upload/read.

### Example Supabase policy (public upload/read)
```sql
create policy "Public read chat media"
on storage.objects for select
using (bucket_id = 'chat-media');

create policy "Public upload chat media"
on storage.objects for insert
with check (bucket_id = 'chat-media');
```

## Firestore Rules (minimum)
Make sure your rules allow:
- Signed‑in users to read `users`.
- Chat participants to read/write their `chats` and `messages`.
- Business owners to manage their `businesses` and `posts`.

## Run
```bash
flutter pub get
flutter run
```

## Windows Installer
To create a single Windows x64 setup executable:
1. Install Visual Studio 2022 Build Tools with the Desktop development with C++ workload.
2. Install Inno Setup 6.
3. From the project root, run:
   ```powershell
   .\windows\installer\build_installer.ps1
   ```
4. The installer is written to `build\windows\installer-output\SpotlightSetup-1.0.0-x64.exe`.

The setup installs the app, Flutter assets, plugin DLLs, and the Visual C++ runtime, then adds Start menu and optional desktop shortcuts. This is a Windows x64 installer, not a single-file portable app; it requires Windows 10 or newer. Unsigned installers may show a SmartScreen warning on PCs where they are first downloaded.

## Launcher Icon
If you want the launcher icon:
```bash
dart run flutter_launcher_icons
```

## Notes
- Search “Users” uses the `users` collection; ensure read rules allow signed‑in users.
- Notifications are derived from post interactions (likes/comments).

## License
Private project. Add a license if needed.
