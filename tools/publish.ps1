# Publishes the current version of Duhuze:
#   1. pushes this code to GitHub main (old main is kept as a backup tag first)
#   2. builds the single Windows installer (.exe)
#   3. creates/updates the GitHub Release with the APKs + the installer
#
#   powershell -ExecutionPolicy Bypass -File .\tools\publish.ps1
#
# Switches: -SkipGit  -SkipInstaller  -SkipRelease
# Run tools\build-release.ps1 -NextBuild -Apk first (it makes release\<version>\).
param([switch]$SkipGit, [switch]$SkipInstaller, [switch]$SkipRelease)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo

function Run([string]$exe, [string[]]$a) {
  # Native tools write progress to stderr; do not let PowerShell treat that as an error.
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  & $exe @a 2>&1 | ForEach-Object { "$_" } | Out-Host
  $code = $LASTEXITCODE
  $ErrorActionPreference = $old
  if ($code -ne 0) { throw "$exe $($a -join ' ') failed (exit $code)" }
}

$pub = [IO.File]::ReadAllText((Join-Path $repo 'pubspec.yaml'))
$m = [regex]::Match($pub, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)')
if (-not $m.Success) { throw 'pubspec.yaml has no version line.' }
$ver = $m.Groups[1].Value; $build = $m.Groups[2].Value
$tag = "v$ver-$build"
$relDir = Join-Path $repo "release\$ver-$build"
Write-Host "Publishing Duhuze $ver (build $build)  tag $tag" -ForegroundColor Cyan

# ---- 1. GitHub: code -> main --------------------------------------------
if (-not $SkipGit) {
  $branch = (& git rev-parse --abbrev-ref HEAD).Trim()
  Write-Host "Branch: $branch"
  Run git @('fetch', 'origin', 'main')
  $backup = "backup-main-" + (Get-Date -Format 'yyyyMMdd-HHmm')
  Run git @('tag', $backup, 'origin/main')
  Run git @('push', 'origin', $backup)
  Run git @('push', 'origin', $branch)
  Run git @('push', 'origin', "${branch}:main", '--force')
  Write-Host "main now equals $branch. Old main saved as tag $backup." -ForegroundColor Green
}

# ---- 2. Windows installer ----------------------------------------------
$exe = $null
if (-not $SkipInstaller) {
  Run powershell @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
    (Join-Path $repo 'windows\installer\build_installer.ps1'))
  $exe = Get-ChildItem (Join-Path $repo 'build\windows\installer-output') -Filter 'Duhuze-Setup-*.exe' |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $exe) { throw 'Installer .exe not found in build\windows\installer-output.' }
  New-Item -ItemType Directory -Force $relDir | Out-Null
  Copy-Item $exe.FullName $relDir -Force
  Write-Host "Installer: $(Join-Path $relDir $exe.Name)" -ForegroundColor Green
}

# ---- 3. GitHub release ---------------------------------------------------
if (-not $SkipRelease) {
  if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host "GitHub CLI (gh) is not installed. Run:  winget install GitHub.cli   then  gh auth login   and run this script again with -SkipGit -SkipInstaller" -ForegroundColor Yellow
    exit 0
  }
  $files = @()
  $files += Get-ChildItem $relDir -Filter '*.apk' | ForEach-Object FullName
  $files += Get-ChildItem $relDir -Filter 'Duhuze-Setup-*.exe' -ErrorAction SilentlyContinue | ForEach-Object FullName
  if (-not $files) { throw "No APK/exe files in $relDir" }
  $notes = "Duhuze $ver (build $build).`n`nAndroid: install duhuze-$ver-$build-arm64-v8a-release.apk (most phones).`nWindows: run Duhuze-Setup-$ver-x64.exe."
  & gh release view $tag *> $null
  if ($LASTEXITCODE -eq 0) {
    Run gh (@('release', 'upload', $tag) + $files + @('--clobber'))
  } else {
    Run gh (@('release', 'create', $tag) + $files + @('--title', "Duhuze $ver (build $build)", '--notes', $notes, '--target', 'main'))
  }
  Write-Host "GitHub release $tag is up." -ForegroundColor Green
}

Write-Host "`nNext: upload the .exe and the arm64 .apk from $relDir to Google Drive (Share -> Anyone with the link)." -ForegroundColor Cyan
