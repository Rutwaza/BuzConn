# Moves the Duhuze website (privacy, terms, delete-account, child-safety pages)
# to a Firebase Hosting site name of your choice: https://<SiteId>.web.app
#
#   powershell -ExecutionPolicy Bypass -File .\tools\set-website.ps1 duhuze-app
#
# It (1) creates the site if needed, (2) writes the new name into firebase.json,
# the app (AppConstants.websiteUrl) and the docs, (3) deploys the website.
# Site names are global: if Firebase says the name is reserved, try another.
# Later, a custom domain (e.g. duhuze.rw) can be connected in Firebase console
# > Hosting > Add custom domain, then run this again is NOT needed: just change
# AppConstants.websiteUrl and the docs to the domain.
param([Parameter(Mandatory = $true)][string]$SiteId)
. "$PSScriptRoot\_common.ps1"
Set-Location $RepoRoot

if ($SiteId -notmatch '^[a-z0-9][a-z0-9-]{3,28}[a-z0-9]$') {
  throw 'Use 5-30 lowercase letters, numbers or hyphens, e.g. duhuze-app'
}

# 1. Create the site if it does not exist yet.
$sites = firebase hosting:sites:list --project $Project --json | Out-String
if ($sites -notmatch "sites/$SiteId`"") {
  Write-Host "Creating Hosting site $SiteId ..." -ForegroundColor Cyan
  firebase hosting:sites:create $SiteId --project $Project --non-interactive
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Firebase refused '$SiteId' (probably reserved by someone else). Try another name." -ForegroundColor Red
    exit 1
  }
}

# 2. Write the new address everywhere.
$utf8 = New-Object Text.UTF8Encoding($false)
$fbPath = Join-Path $RepoRoot 'firebase.json'
$fb = [IO.File]::ReadAllText($fbPath, $utf8)
$old = [regex]::Match($fb, '"site"\s*:\s*"([^"]+)"').Groups[1].Value
$fb = [regex]::Replace($fb, '"site"\s*:\s*"[^"]+"', "`"site`": `"$SiteId`"")
[IO.File]::WriteAllText($fbPath, $fb, $utf8)

$newUrl = "https://$SiteId.web.app"
$files = @('lib\core\constants\app_constants.dart', 'README.md') + (Get-ChildItem docs\*.md | ForEach-Object { "docs\$($_.Name)" })
foreach ($f in $files) {
  $p = Join-Path $RepoRoot $f
  $text = [IO.File]::ReadAllText($p, $utf8)
  $new = $text
  if ($old) { $new = $new.Replace("https://$old.web.app", $newUrl) }
  $new = [regex]::Replace($new, "static const String websiteUrl = '[^']*';", "static const String websiteUrl = '$newUrl';")
  if ($new -ne $text) { [IO.File]::WriteAllText($p, $new, $utf8); Write-Host "Updated $f" }
}

# 3. Deploy the website.
firebase deploy --only hosting --project $Project
if ($LASTEXITCODE -ne 0) { throw 'Website deploy failed (see above).' }

Write-Host "`nWebsite is live: $newUrl/privacy" -ForegroundColor Green
Write-Host "Next: commit (git commit -am `"Website: $newUrl`") and rebuild the app so its links use the new address."
if ($old -and $old -ne $SiteId) {
  Write-Host "Unused site '$old'? Delete it:  firebase hosting:sites:delete $old --project $Project"
}
