# Duhuze - deploy Firestore rules + indexes, Realtime Database rules and all
# Cloud Functions. Functions go up in small groups so Google's CPU quota for
# starting new versions is never exceeded.
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

Write-Host "`n== Rules and indexes ==" -ForegroundColor Cyan
firebase deploy --only firestore:rules,firestore:indexes,database --project $project

$groups = @(
  @('sendNotificationDocumentPush','sendIncomingCallPush','notifyOnChatMessage','notifyOnFollow'),
  @('createR2UploadUrl','createR2DownloadUrl','claimUsername','getSystemCounts'),
  @('onPostLiked','onPostUnliked','onCommentCreated','onCommentDeleted'),
  @('onCommentLiked','onPostCreatedFeed','onPostEditedFeed','refreshTrendingScores'),
  @('onUserFollowTimeline','onPageFollowTimeline','userSearchKeywords','pageSearchKeywords'),
  @('countNotificationCreated','countNotificationUpdated','countNotificationDeleted'),
  @('setEntityActive','exportEntityData','exportChatBetweenUsers'),
  @('phase2Maintenance','phase3Maintenance')
)
$failed = @()
$i = 0
foreach ($g in $groups) {
  $i++
  Write-Host "`n== Functions group $i of $($groups.Count): $($g -join ', ') ==" -ForegroundColor Cyan
  $only = ($g | ForEach-Object { "functions:$_" }) -join ','
  firebase deploy --only $only --force --project $project
  if ($LASTEXITCODE -ne 0) { $failed += $g }
  Start-Sleep -Seconds 20   # let the CPU used by the health checks free up
}

if ($failed.Count -gt 0) {
  Write-Host "`nThese functions failed: $($failed -join ', ')" -ForegroundColor Red
  Write-Host "Run the script again (it is safe), or send the red lines to Claude." -ForegroundColor Red
  exit 1
}
Write-Host "`nDone - everything deployed." -ForegroundColor Green
