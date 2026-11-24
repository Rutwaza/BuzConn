# Creates the Google Play UPLOAD KEY for Duhuze (run once, ever).
#
#   powershell -ExecutionPolicy Bypass -File .\tools\create-upload-key.ps1
#
# - The key file goes to  %USERPROFILE%\duhuze-keys\duhuze-upload.jks
#   (outside the project, so it is never pushed to Git).
# - android\key.properties is written so release builds use it.
# - BACK UP the .jks file and the password (e.g. USB stick + password
#   manager). With Play App Signing, Google can reset a lost upload key,
#   but it takes days and a support request.
. "$PSScriptRoot\_common.ps1"

$keytool = Find-Keytool
$dir = Join-Path $env:USERPROFILE 'duhuze-keys'
$keystore = Join-Path $dir 'duhuze-upload.jks'
if (Test-Path $keystore) {
  Write-Host "An upload key already exists at $keystore - not making a new one." -ForegroundColor Yellow
  Write-Host "Delete it by hand only if you are sure it was never used on Google Play."
  exit 1
}
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$p1 = Read-Host 'Choose a password for the upload key (min 6 characters)' -AsSecureString
$p2 = Read-Host 'Type it again' -AsSecureString
$plain1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1))
$plain2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2))
if ($plain1 -ne $plain2 -or $plain1.Length -lt 6) { throw 'Passwords do not match or are too short.' }

& $keytool -genkeypair -v -keystore $keystore -storetype JKS -keyalg RSA -keysize 2048 `
  -validity 10000 -alias upload -dname 'CN=Duhuze, O=Duhuze, C=RW' `
  -storepass $plain1 -keypass $plain1
if ($LASTEXITCODE -ne 0) { throw 'keytool failed.' }

$props = @(
  "# Duhuze upload key - NEVER commit this file (it is in .gitignore)."
  "storePassword=$plain1"
  "keyPassword=$plain1"
  "keyAlias=upload"
  "storeFile=$($keystore -replace '\\','/')"
)
Set-Content -Path (Join-Path $RepoRoot 'android\key.properties') -Value $props -Encoding ASCII

$fp = Get-Fingerprints $keytool $keystore 'upload' $plain1
Write-Host "`nUpload key created: $keystore" -ForegroundColor Green
Write-Host "SHA-1:   $($fp.SHA1)"
Write-Host "SHA-256: $($fp.SHA256)"
Write-Host "`nNOW: back up $keystore and the password. Then run tools\register-android-app.ps1." -ForegroundColor Yellow
