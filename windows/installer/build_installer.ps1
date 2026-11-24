param(
    [string]$InnoSetupCompiler,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$releaseDir = Join-Path $repoRoot 'build\windows\x64\runner\Release'
$payloadDir = Join-Path $repoRoot 'build\windows\x64\installer-payload'
$scriptPath = Join-Path $PSScriptRoot 'Duhuze.iss'
$oauthConfig = Join-Path $repoRoot 'windows_google_oauth.json'

Push-Location $repoRoot
try {
    if (-not $SkipBuild) {
        $flutterArgs = @('build', 'windows', '--release')
        if (Test-Path -LiteralPath $oauthConfig) {
            $flutterArgs += "--dart-define-from-file=$oauthConfig"
        }
        & flutter @flutterArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Flutter Windows release build failed with exit code $LASTEXITCODE."
        }
    }

    $appExecutable = Join-Path $releaseDir 'Duhuze.exe'
    $dataDirectory = Join-Path $releaseDir 'data'
    if (-not (Test-Path $appExecutable) -or -not (Test-Path $dataDirectory)) {
        throw "Flutter release output is incomplete: $releaseDir"
    }

    if (Test-Path $payloadDir) {
        Remove-Item -LiteralPath $payloadDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $payloadDir | Out-Null

    Copy-Item -LiteralPath $appExecutable -Destination $payloadDir
    Get-ChildItem -LiteralPath $releaseDir -Filter '*.dll' -File |
        Copy-Item -Destination $payloadDir
    Copy-Item -LiteralPath $dataDirectory -Destination $payloadDir -Recurse

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) {
        throw 'Could not locate vswhere.exe to find the Visual C++ runtime.'
    }
    $vsInstallPath = & $vswhere -latest -products '*' -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $vsInstallPath) {
        throw 'Could not locate a Visual Studio installation with the C++ runtime.'
    }

    $redistRoot = Join-Path $vsInstallPath 'VC\Redist\MSVC'
    $crtDirectory = Get-ChildItem -LiteralPath $redistRoot -Directory |
        Where-Object { $_.Name -match '^\d' } |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object {
            Join-Path $_.FullName 'x64\Microsoft.VC143.CRT'
        } |
        Where-Object { Test-Path (Join-Path $_ 'vcruntime140.dll') } |
        Select-Object -First 1

    if (-not $crtDirectory) {
        throw "Could not find the x64 Visual C++ 2015-2022 runtime under $redistRoot."
    }
    Get-ChildItem -LiteralPath $crtDirectory -Filter '*.dll' -File |
        Copy-Item -Destination $payloadDir

    if (-not $InnoSetupCompiler) {
        $compilerCandidates = @(
            (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
            (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
        )
        $InnoSetupCompiler = $compilerCandidates |
            Where-Object { Test-Path $_ } |
            Select-Object -First 1
    }
    if (-not (Test-Path $InnoSetupCompiler)) {
        throw 'Inno Setup 6 is required. Install it, or pass its ISCC.exe path with -InnoSetupCompiler.'
    }

    & $InnoSetupCompiler $scriptPath
    if ($LASTEXITCODE -ne 0) {
        throw "Inno Setup compilation failed with exit code $LASTEXITCODE."
    }

    $installer = Join-Path $repoRoot 'build\windows\installer-output\Duhuze-Setup-1.0.0-x64.exe'
    if (-not (Test-Path $installer)) {
        throw "Installer compilation reported success but did not create $installer."
    }
    Write-Output "Installer created: $installer"
}
finally {
    Pop-Location
}
