# Duhuze - deploy everything: Firestore rules + indexes, Realtime Database rules,
# and ALL Cloud Functions. First deletes the old transport functions.
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

# 1) Delete the old transport functions first: they still hold CPU quota.
$old = @(
  'approveAgencyApplication','assignAgencyStaffRole','assignRouteToBus',
  'backfillDiscoveredBuses','backfillRouteSegments','bookSeat','bookSeatV1',
  'createOrUpdateBus','createOrUpdateRoute','deleteRoute','expireBookings',
  'getAgencyFinancialReport','getSystemFinanceBreakdown','markBusTurnaround',
  'openAgencyByPassword','registerCardToUser','rejectAgencyApplication',
  'releaseBookingSeat','releasePaidSeats','requestAgencyPasswordReset',
  'requestCardStatusChange','requestDirection','resolveAgencyPasswordReset',
  'resolveDirectionRequest','sendNotificationPush','setAgencyAccessPassword',
  'setCardActive','submitAgencyApplication','syncDiscoveredBus','tapCard',
  'topUpCard','unassignRouteFromBus','updateBankAccounts'
)
Write-Host "`n== Deleting old transport functions ==" -ForegroundColor Cyan
firebase functions:delete @old --region us-central1 --force --project $project

# 2) Deploy everything (functions now capped at 10 instances each).
Write-Host "`n== Deploying to $project ==" -ForegroundColor Cyan
firebase deploy --only firestore:rules,firestore:indexes,database,functions --force --project $project
if ($LASTEXITCODE -ne 0) {
  Write-Host "`nDeploy failed: copy the red lines above and send them to Claude." -ForegroundColor Red
  exit 1
}
Write-Host "`nDone." -ForegroundColor Green
