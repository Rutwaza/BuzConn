# Duhuze - deploy everything: Firestore rules + indexes, Realtime Database rules,
# and ALL Cloud Functions. The old transport (bus/booking/card/agency) functions
# are no longer in the source, so Firebase will ask to delete them: answer  y
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

Write-Host "`n== Deploying to $project ==" -ForegroundColor Cyan
Write-Host "If asked 'Would you like to proceed with deletion?' type  y  and press Enter." -ForegroundColor Yellow
firebase deploy --only firestore:rules,firestore:indexes,database,functions --project $project
if ($LASTEXITCODE -ne 0) {
  Write-Host "`nDeploy failed: copy the red lines above and send them to Claude." -ForegroundColor Red
  exit 1
}
Write-Host "`nDone." -ForegroundColor Green
