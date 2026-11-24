# Duhuze - smart deploy: only what changed since the last successful deploy.
#
#   cd C:\Users\Nexon\Desktop\PROJECTS\BussFinder\bussinessfinder
#   powershell -ExecutionPolicy Bypass -File .\deploy.ps1              # only changes
#   powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -DryRun      # just show the plan
#   powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -All         # everything
#   powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -Functions onPostLiked,claimUsername
#
# How it decides:
#   firestore.rules         -> Firestore rules
#   firestore.indexes.json  -> Firestore indexes
#   database.rules.json     -> Realtime Database rules
#   site/...                -> website (privacy, terms, delete-account pages)
#   functions/<file>.js     -> only the functions defined in that file
#   functions/package*.json, or setGlobalOptions in index.js -> all functions
# The last deployed Git commit is kept in .deploy-state (not in Git).
param(
  [switch]$All,
  [switch]$DryRun,
  [string[]]$Functions
)
$ErrorActionPreference = 'Continue'
$project = 'bussinessfinder-327f5'
$stateFile = Join-Path $PSScriptRoot '.deploy-state'
Set-Location $PSScriptRoot

# ---- 1. What changed? ------------------------------------------------------
$last = if (Test-Path $stateFile) { (Get-Content $stateFile -Raw).Trim() } else { '' }
$changed = @()
if (-not $All -and -not $Functions) {
  if ($last) {
    $changed += git diff --name-only $last HEAD
  } else {
    Write-Host "No .deploy-state yet: deploying everything once." -ForegroundColor Yellow
    $All = $true
  }
  $changed += git diff --name-only HEAD                      # not committed yet
  $changed += git ls-files --others --exclude-standard        # new files
  $changed = $changed | Where-Object { $_ } | Sort-Object -Unique
}

Push-Location functions
if (-not (Test-Path node_modules) -or ($changed -match '^functions/package(-lock)?\.json$')) {
  npm ci --silent
}
$map = node scripts/function-map.js | ConvertFrom-Json
Pop-Location
if (-not $map) { Write-Host "Could not read the functions list (see error above)." -ForegroundColor Red; exit 1 }
$allFns = @()
foreach ($p in $map.PSObject.Properties) { $allFns += $p.Value }

$targets = @()
$fns = @()
if ($All) {
  $targets = @('firestore:rules', 'firestore:indexes', 'database', 'hosting')
  $fns = $allFns
} elseif ($Functions) {
  $fns = $Functions | ForEach-Object { $_ -split ',' } | Where-Object { $_ }
} else {
  if ($changed -contains 'firestore.rules') { $targets += 'firestore:rules' }
  if ($changed -contains 'firestore.indexes.json') { $targets += 'firestore:indexes' }
  if ($changed -contains 'database.rules.json') { $targets += 'database' }
  if (($changed | Where-Object { $_ -like 'site/*' }) -or ($changed -contains 'firebase.json')) { $targets += 'hosting' }
  $everything = ($changed | Where-Object { $_ -match '^functions/package(-lock)?\.json$' }).Count -gt 0
  if ($changed -contains 'functions/index.js') {
    $diff = if ($last) { git diff $last -- functions/index.js } else { '' }
    if ("$diff" -match 'setGlobalOptions') { $everything = $true }
  }
  if ($everything) {
    $fns = $allFns
  } else {
    foreach ($file in $changed) {
      if ($file -match '^functions/([^/]+\.js)$') {
        $prop = $map.PSObject.Properties[$Matches[1]]
        if ($prop) { $fns += $prop.Value }
      }
    }
  }
}
$fns = @($fns | Sort-Object -Unique)

Write-Host "`n== Plan ==" -ForegroundColor Cyan
if ($changed) { Write-Host "Changed files: $($changed -join ', ')" }
Write-Host "Rules/indexes: $(if ($targets) { $targets -join ', ' } else { 'nothing' })"
Write-Host "Functions ($($fns.Count)): $(if ($fns) { $fns -join ', ' } else { 'nothing' })"
if ($DryRun) { exit 0 }
if (-not $targets -and -not $fns) {
  Write-Host "`nNothing to deploy - Firebase is already up to date." -ForegroundColor Green
  git rev-parse HEAD | Set-Content $stateFile
  exit 0
}

# The website must not go live with placeholders in the legal pages.
if ($targets -contains 'hosting') {
  $left = Select-String -Path 'site\*.html' -Pattern 'CHANGE_ME' -List
  if ($left) {
    Write-Host "`nWebsite NOT deployed: replace CHANGE_ME_EMAIL / CHANGE_ME_OWNER in:" -ForegroundColor Yellow
    $left | ForEach-Object { Write-Host "  $($_.Path)" }
    $targets = @($targets | Where-Object { $_ -ne 'hosting' })
    $hostingSkipped = $true
  }
}

# The website's Hosting site name is in firebase.json ("site"). If it does not
# exist yet, tools\set-website.ps1 creates it (names are global, some are taken).
if ($targets -contains 'hosting') {
  $siteId = ((Get-Content firebase.json -Raw) | ConvertFrom-Json).hosting.site
  $sitesJson = firebase hosting:sites:list --project $project --json | Out-String
  if ($siteId -and $sitesJson -notmatch "sites/$siteId`"") {
    Write-Host "Hosting site '$siteId' does not exist. Run:  .\tools\set-website.ps1 <name>" -ForegroundColor Yellow
    $targets = @($targets | Where-Object { $_ -ne 'hosting' })
    $hostingSkipped = $true
  }
}

# ---- 2. Prepare -------------------------------------------------------------
firebase login   # says "Already logged in" if you are signed in

if ($fns -contains 'archiveGhostMessage' -or $fns -contains 'decryptGhostArchive') {
  firebase functions:secrets:access GHOST_ARCHIVE_KEY --project $project *> $null
  if ($LASTEXITCODE -ne 0) {
    # First time only: make a random 32-byte key and keep it in Secret Manager.
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $tmp = New-TemporaryFile
    [IO.File]::WriteAllText($tmp, [Convert]::ToBase64String($bytes))
    firebase functions:secrets:set GHOST_ARCHIVE_KEY --data-file $tmp --project $project
    Remove-Item $tmp
    Write-Host "Ghost archive key created (kept in Google Secret Manager)." -ForegroundColor Green
  }
}

# ---- 3. Deploy --------------------------------------------------------------
$failed = @()
if ($targets) {
  Write-Host "`n== Rules and indexes: $($targets -join ', ') ==" -ForegroundColor Cyan
  firebase deploy --only ($targets -join ',') --project $project
  if ($LASTEXITCODE -ne 0) { $failed += $targets }
}

# Functions go in groups of 4 so Google's CPU quota is never exceeded.
for ($i = 0; $i -lt $fns.Count; $i += 4) {
  $group = $fns[$i..([Math]::Min($i + 3, $fns.Count - 1))]
  Write-Host "`n== Functions: $($group -join ', ') ==" -ForegroundColor Cyan
  firebase deploy --only (($group | ForEach-Object { "functions:$_" }) -join ',') --force --project $project
  if ($LASTEXITCODE -ne 0) { $failed += $group }
  if ($i + 4 -lt $fns.Count) { Start-Sleep -Seconds 20 }
}

if ($failed.Count -gt 0) {
  Write-Host "`nThese failed: $($failed -join ', ')" -ForegroundColor Red
  $retryFns = @($failed | Where-Object { $allFns -contains $_ })
  if ($retryFns) { Write-Host "Retry the functions:  .\deploy.ps1 -Functions $($retryFns -join ',')" -ForegroundColor Red }
  if ($failed | Where-Object { $allFns -notcontains $_ }) {
    Write-Host "Rules/indexes/website failed: fix the error above and run .\deploy.ps1 again." -ForegroundColor Red
  }
  exit 1
}
if ($hostingSkipped) {
  Write-Host "`nDone, except the website (placeholders). Not saving .deploy-state so it is retried next time." -ForegroundColor Yellow
  exit 0
}
git rev-parse HEAD | Set-Content $stateFile
Write-Host "`nDone - deployed. Saved this point in .deploy-state." -ForegroundColor Green
