# Registers rw.duhuze.app in Firebase, adds the signing fingerprints (needed
# for Google and phone sign-in) and downloads the matching google-services.json.
#
#   powershell -ExecutionPolicy Bypass -File .\tools\register-android-app.ps1
#   ... -PlaySigningSha1 AA:BB:...   (after the first Play upload, see docs/RELEASE.md)
#
# Safe to run again: it reuses the app and skips fingerprints already added.
param([string]$PlaySigningSha1, [string]$PlaySigningSha256)
. "$PSScriptRoot\_common.ps1"
Set-Location $RepoRoot

Write-Host "== Firebase sign-in ==" -ForegroundColor Cyan
firebase login

# 1. Find or create the Android app.
$apps = (firebase apps:list ANDROID --project $Project --json | Out-String | ConvertFrom-Json).result
$app = $apps | Where-Object { $_.packageName -eq $AppId } | Select-Object -First 1
if (-not $app) {
  Write-Host "Creating Android app $AppId in Firebase..." -ForegroundColor Cyan
  $created = firebase apps:create ANDROID 'Duhuze' --package-name $AppId --project $Project --json | Out-String | ConvertFrom-Json
  $app = $created.result
}
$firebaseAppId = $app.appId
Write-Host "Firebase Android app: $firebaseAppId"

# 2. Fingerprints: debug key (development), upload key, and Play's app signing key.
$keytool = Find-Keytool
$shas = @()
$debugKeystore = Join-Path $env:USERPROFILE '.android\debug.keystore'
if (Test-Path $debugKeystore) {
  $fp = Get-Fingerprints $keytool $debugKeystore 'androiddebugkey' 'android'
  $shas += $fp.SHA1, $fp.SHA256
} else {
  Write-Host "No debug keystore yet (it appears after your first 'flutter run'). Run this script again then." -ForegroundColor Yellow
}
$props = Read-KeyProperties
if ($props) {
  $fp = Get-Fingerprints $keytool $props['storeFile'] $props['keyAlias'] $props['storePassword']
  $shas += $fp.SHA1, $fp.SHA256
} else {
  Write-Host "No upload key yet - run tools\create-upload-key.ps1 first for release builds." -ForegroundColor Yellow
}
if ($PlaySigningSha1) { $shas += $PlaySigningSha1 }
if ($PlaySigningSha256) { $shas += $PlaySigningSha256 }

$existing = (firebase apps:android:sha:list $firebaseAppId --project $Project --json | Out-String | ConvertFrom-Json).result |
  ForEach-Object { ($_.shaHash -replace ':','').ToUpper() }
foreach ($sha in ($shas | Where-Object { $_ } | Sort-Object -Unique)) {
  $plain = ($sha -replace ':','').ToUpper()
  if ($existing -contains $plain) { Write-Host "Fingerprint already added: $sha"; continue }
  firebase apps:android:sha:create $firebaseAppId $sha --project $Project | Out-Null
  Write-Host "Added fingerprint: $sha" -ForegroundColor Green
}

# 3. Download the config the build uses.
$target = Join-Path $RepoRoot 'android\app\google-services.json'
if (Test-Path $target) { Copy-Item $target "$target.bak" -Force }
firebase apps:sdkconfig ANDROID $firebaseAppId --project $Project --out $target
if (-not (Select-String -Path $target -Pattern $AppId -Quiet)) { throw "Downloaded config does not mention $AppId." }

Write-Host "`nDone. android\app\google-services.json now belongs to $AppId (old copy: google-services.json.bak)." -ForegroundColor Green
Write-Host "Builds now use the id $AppId. Check Google sign-in works on a phone." -ForegroundColor Green
Write-Host "Note: in Firebase console > Authentication, Google sign-in uses the new fingerprints automatically."
