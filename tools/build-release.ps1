# Builds the files for Google Play (and an APK to share for testing).
#
#   powershell -ExecutionPolicy Bypass -File .\tools\build-release.ps1 -NextBuild
#   powershell -ExecutionPolicy Bypass -File .\tools\build-release.ps1 -Version 1.1.0
#   add -Apk to also make installable APKs for testers
#
# Every upload to Google Play needs a HIGHER build number (the +N in
# pubspec.yaml "version: 1.0.0+N"). -NextBuild adds 1; -Version sets the
# visible version and also adds 1.
#
# Output: release\<version>\
#   duhuze-<version>.aab        -> upload this to Google Play
#   duhuze-<version>-*.apk      -> install by hand / send to testers (-Apk)
#   debug-info-<version>.zip    -> KEEP: needed to read crash reports
param([switch]$NextBuild, [string]$Version, [switch]$Apk)
. "$PSScriptRoot\_common.ps1"
Set-Location $RepoRoot

# ---- Checks -------------------------------------------------------------------
$problems = @()
if (-not (Read-KeyProperties)) { $problems += 'android\key.properties missing: run tools\create-upload-key.ps1 (Play rejects debug-signed bundles).' }
if (-not (Select-String -Path 'android\app\google-services.json' -Pattern $AppId -Quiet)) {
  $problems += "google-services.json is not for $AppId yet: run tools\register-android-app.ps1."
}
if ($problems) {
  $problems | ForEach-Object { Write-Host "! $_" -ForegroundColor Yellow }
  $answer = Read-Host 'Build anyway (only for testing, not for Play)? y/N'
  if ($answer -ne 'y') { exit 1 }
}

# ---- Version -----------------------------------------------------------------
$pubspec = Get-Content pubspec.yaml -Raw
$m = [regex]::Match($pubspec, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)')
if (-not $m.Success) { throw 'pubspec.yaml has no "version: x.y.z+N" line.' }
$name = $m.Groups[1].Value; $build = [int]$m.Groups[2].Value
if ($Version) { $name = $Version; $build++ } elseif ($NextBuild) { $build++ }
$pubspec = $pubspec.Remove($m.Index, $m.Length).Insert($m.Index, "version: $name+$build")
Set-Content pubspec.yaml $pubspec -NoNewline
$tag = "$name+$build"
Write-Host "== Building Duhuze $tag ==" -ForegroundColor Cyan

# ---- Build -------------------------------------------------------------------
$out = Join-Path $RepoRoot "release\$name-$build"
$debugInfo = Join-Path $RepoRoot "build\debug-info\$name-$build"
New-Item -ItemType Directory -Force -Path $out, $debugInfo | Out-Null

flutter pub get
flutter build appbundle --release --obfuscate --split-debug-info=$debugInfo
if ($LASTEXITCODE -ne 0) { throw 'App Bundle build failed (see the red lines above).' }
Copy-Item 'build\app\outputs\bundle\release\app-release.aab' (Join-Path $out "duhuze-$name-$build.aab")

if ($Apk) {
  flutter build apk --release --split-per-abi --obfuscate --split-debug-info=$debugInfo
  if ($LASTEXITCODE -ne 0) { throw 'APK build failed.' }
  Get-ChildItem 'build\app\outputs\flutter-apk\app-*-release.apk' | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $out ($_.Name -replace '^app-', "duhuze-$name-$build-"))
  }
}
Compress-Archive -Path "$debugInfo\*" -DestinationPath (Join-Path $out "debug-info-$name-$build.zip") -Force

Write-Host "`nDone. Files in $out :" -ForegroundColor Green
Get-ChildItem $out | ForEach-Object { Write-Host "  $($_.Name)  ($([math]::Round($_.Length/1MB,1)) MB)" }
Write-Host "`nCommit the new version number:  git commit -am `"Release $tag`"" -ForegroundColor Yellow
Write-Host "Upload the .aab in Play Console (docs/RELEASE.md, step 7)."
