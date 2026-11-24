# Duhuze - finish Phase 1 + Phase 2 (run once from the project folder)
#
#   cd C:\Users\Nexon\Desktop\PROJECTS\BussFinder\bussinessfinder
#   powershell -ExecutionPolicy Bypass -File .\finish_phase1_phase2.ps1
#
# What it does, in order:
#   1. Removes old files that were moved or are no longer used
#   2. flutter pub get + flutter analyze
#   3. Saves everything in Git on the phase-1 branch
#   4. Deploys the database rules and ONLY the social Cloud Functions
#      (not the bus/booking ones)
#   5. Prints your Realtime Database URL so we can check it in the app
$ErrorActionPreference = 'Stop'
$project = 'bussinessfinder-327f5'

Write-Host "`n== 1. Removing old files ==" -ForegroundColor Cyan
$old = @(
  'lib/features/dashboard/dashboard_page.dart',
  'lib/presentation/pages/test_storage_page.dart',
  'lib/core/services/social_notification_service.dart',
  'lib/data/repositories/chat_repository.dart',
  'lib/presentation/pages/chat/chat_page.dart',
  'lib/presentation/pages/chat/chat_list_page.dart',
  'lib/presentation/pages/chat/video_call_page.dart',
  'windows/installer/Spotlight.iss',
  'assets/images/spotlight_logo.png'
)
foreach ($f in $old) {
  if (Test-Path $f) { git rm -q --ignore-unmatch $f 2>$null; if (Test-Path $f) { Remove-Item $f }; Write-Host "  removed $f" }
}

Write-Host "`n== 2. Packages and code check ==" -ForegroundColor Cyan
flutter pub get
flutter analyze lib | Select-String -Pattern "^\s*error" | ForEach-Object { $_.Line }
Write-Host "  (no lines above = no errors)"

Write-Host "`n== 3. Saving in Git ==" -ForegroundColor Cyan
$branch = (git branch --show-current).Trim()
if ($branch -ne 'phase-1') {
  git checkout -b phase-1 2>$null; if ($LASTEXITCODE -ne 0) { git checkout phase-1 }
}
git add -A
git commit -q -m "Phase 1 + 2: security, Duhuze rename, fast chat, likes/comments as documents"
git log --oneline -1

Write-Host "`n== 4. Deploying to Firebase ($project) ==" -ForegroundColor Cyan
firebase login   # says "Already logged in" if you are signed in
Push-Location functions
npm ci
Pop-Location
$fns = @(
  'sendNotificationDocumentPush', 'notifyOnFollow', 'notifyOnChatMessage',
  'onPostLiked', 'onPostUnliked', 'onCommentCreated', 'onCommentDeleted',
  'onCommentLiked', 'phase2Maintenance'
) | ForEach-Object { "functions:$_" }
$only = (@('firestore:rules', 'database') + $fns) -join ','
firebase deploy --only $only --project $project

Write-Host "`n== 5. Your Realtime Database URL ==" -ForegroundColor Cyan
firebase database:instances:list --project $project
Write-Host "`nDone. Send Claude the URL above (the one ending in firebaseio.com or firebasedatabase.app)." -ForegroundColor Green
