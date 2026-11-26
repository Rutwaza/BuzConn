# Makes site/.well-known/assetlinks.json so Android opens Duhuze links
# (https://duhuze-rw.web.app/p/... and /g/...) straight in the app, without
# the "Open with" question.
#
#   powershell -ExecutionPolicy Bypass -File .\tools\make-assetlinks.ps1
#   powershell -ExecutionPolicy Bypass -File .\tools\make-assetlinks.ps1 -PlayKey "AB:CD:...:EF"
#
# It lists the SHA-256 fingerprints of:
#   - your upload key (android\key.properties): APKs you build and share
#   - the debug key (~\.android\debug.keystore): "flutter run" builds
#   - -PlayKey: the "App signing key" SHA-256 from Play Console
#     (Test and release -> Setup -> App signing). Add it once the app is on
#     Google Play, because Play re-signs the app with that key.
# Then run .\deploy.ps1 to publish it, and reinstall the app.
param([string]$PlayKey)
. "$PSScriptRoot\_common.ps1"
Set-Location $RepoRoot

$keytool = Find-Keytool
$prints = @()

$props = Read-KeyProperties
if ($props) {
  $f = Get-Fingerprints $keytool $props['storeFile'] $props['keyAlias'] $props['storePassword']
  Write-Host "Upload key:  $($f.SHA256)"
  $prints += $f.SHA256
} else {
  Write-Host "No android\key.properties: skipping the upload key." -ForegroundColor Yellow
}

$debugStore = Join-Path $env:USERPROFILE '.android\debug.keystore'
if (Test-Path $debugStore) {
  $f = Get-Fingerprints $keytool $debugStore 'androiddebugkey' 'android'
  Write-Host "Debug key:   $($f.SHA256)"
  $prints += $f.SHA256
}

if ($PlayKey) {
  $k = $PlayKey.Trim().ToUpper()
  if ($k -notmatch '^([0-9A-F]{2}:){31}[0-9A-F]{2}$') { throw "PlayKey must look like AB:CD:... (32 pairs)." }
  Write-Host "Play key:    $k"
  $prints += $k
}

$prints = @($prints | Where-Object { $_ } | Select-Object -Unique)
if (-not $prints) { throw 'No key found. Run tools\create-upload-key.ps1 first.' }

$items = @(
  [ordered]@{
    relation = @('delegate_permission/common.handle_all_urls')
    target = [ordered]@{
      namespace = 'android_app'
      package_name = $AppId
      sha256_cert_fingerprints = $prints
    }
  }
)
$dir = Join-Path $RepoRoot 'site\.well-known'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$json = ConvertTo-Json -InputObject $items -Depth 6
[IO.File]::WriteAllText((Join-Path $dir 'assetlinks.json'), $json, (New-Object Text.UTF8Encoding($false)))

Write-Host "`nWrote site\.well-known\assetlinks.json ($($prints.Count) key(s))." -ForegroundColor Green
Write-Host "Next: git add site\.well-known; git commit -m `"App links`"; .\deploy.ps1"
Write-Host "Check: https://duhuze-rw.web.app/.well-known/assetlinks.json"
