# Duhuze - deploy rules, indexes and the social/feed Cloud Functions.
# (Bus/booking functions are NOT touched.)
#
#   cd C:\Users\Nexon\Desktop\PROJECTS\BussFinder\bussinessfinder
#   powershell -ExecutionPolicy Bypass -File .\deploy.ps1
$ErrorActionPreference = 'Continue'
$project = 'bussinessfinder-327f5'

Write-Host "`n== Packages ==" -ForegroundColor Cyan
flutter pub get
Push-Location functions
npm ci
Pop-Location

Write-Host "`n== Firebase sign-in ==" -ForegroundColor Cyan
firebase login   # says "Already logged in" if you are signed in

$fns = @(
  # Phase 1-2: notifications, likes, comments
  'sendNotificationDocumentPush', 'notifyOnFollow', 'notifyOnChatMessage',
  'onPostLiked', 'onPostUnliked', 'onCommentCreated', 'onCommentDeleted',
  'onCommentLiked', 'phase2Maintenance',
  # Phase 3: feed, reels, search, unread badge
  'onPostCreatedFeed', 'onPostEditedFeed', 'refreshTrendingScores',
  'onUserFollowTimeline', 'onPageFollowTimeline', 'userSearchKeywords',
  'pageSearchKeywords', 'countNotificationCreated', 'countNotificationUpdated',
  'countNotificationDeleted', 'phase3Maintenance'
) | ForEach-Object { "functions:$_" }
$only = (@('firestore:rules', 'firestore:indexes', 'database') + $fns) -join ','

Write-Host "`n== Deploying to $project ==" -ForegroundColor Cyan
firebase deploy --only $only --project $project
if ($LASTEXITCODE -ne 0) {
  Write-Host "`nDeploy failed: copy the red lines above and send them to Claude." -ForegroundColor Red
  exit 1
}

Write-Host "`n== Realtime Database URL ==" -ForegroundColor Cyan
firebase database:instances:list --project $project
Write-Host "`nDone. Send Claude the URL above." -ForegroundColor Green
