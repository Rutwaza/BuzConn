# Shared helpers for the Duhuze tools scripts. Not run directly.
$ErrorActionPreference = 'Stop'
$Project = 'bussinessfinder-327f5'
$AppId = 'rw.duhuze.app'
$RepoRoot = Split-Path $PSScriptRoot -Parent

function Find-Keytool {
  $candidates = @()
  if ($env:JAVA_HOME) { $candidates += Join-Path $env:JAVA_HOME 'bin\keytool.exe' }
  $candidates += 'C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe'
  $candidates += 'C:\Program Files\Android\Android Studio\jre\bin\keytool.exe'
  foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
  $onPath = Get-Command keytool -ErrorAction SilentlyContinue
  if ($onPath) { return $onPath.Source }
  throw "keytool not found. Install Android Studio (it includes Java) or set JAVA_HOME."
}

function Read-KeyProperties {
  $file = Join-Path $RepoRoot 'android\key.properties'
  if (-not (Test-Path $file)) { return $null }
  $props = @{}
  foreach ($line in Get-Content $file) {
    if ($line -match '^\s*([^#=]+?)\s*=\s*(.*)$') { $props[$Matches[1]] = $Matches[2] }
  }
  return $props
}

function Get-Fingerprints($keytool, $keystore, $alias, $storePass) {
  # keytool prints harmless warnings (e.g. "JKS uses a proprietary format") on
  # stderr. Windows PowerShell 5.1 turns those into errors under 'Stop', so
  # relax it here and read only the normal output.
  $ErrorActionPreference = 'Continue'
  $out = & $keytool -list -v -keystore $keystore -alias $alias -storepass $storePass 2>$null | Out-String
  $sha1 = [regex]::Match($out, 'SHA1:\s*([0-9A-F:]+)').Groups[1].Value
  $sha256 = [regex]::Match($out, 'SHA256:\s*([0-9A-F:]+)').Groups[1].Value
  if (-not $sha1) { throw "Could not read fingerprints from $keystore" }
  return @{ SHA1 = $sha1; SHA256 = $sha256 }
}
