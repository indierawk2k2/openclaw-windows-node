<#
.SYNOPSIS
    Build local OpenClaw Companion Inno installers for quick validation.

.DESCRIPTION
    Publishes the tray app and SetupEngine.UI into a production-style layout,
    then runs ISCC to create local unsigned installers.

    Use -NoPublish after changing only installer.iss or docs/tests; it reuses
    the existing publish-local-* payloads and only recompiles Inno.

.EXAMPLE
    .\scripts\build-inno-local.ps1 -Arch x64 -Fast
    .\scripts\build-inno-local.ps1 -Arch All
    .\scripts\build-inno-local.ps1 -Arch x64 -NoPublish -Fast
#>

[CmdletBinding()]
param(
    [ValidateSet("x64", "arm64", "All")]
    [string]$Arch = "x64",

    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",

    [string]$Version,

    [switch]$NoPublish,

    [switch]$Fast,

    [switch]$InstallInno,

    [string]$PackageIdentitySigningThumbprint = $env:OPENCLAW_PACKAGE_IDENTITY_SIGNING_THUMBPRINT
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

function Write-Step {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Resolve-InnoCompiler {
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    if ($InstallInno) {
        Write-Step "Installing Inno Setup with winget"
        winget install --id JRSoftware.InnoSetup -e --accept-source-agreements --accept-package-agreements --disable-interactivity
        if ($LASTEXITCODE -ne 0) {
            throw "winget failed to install Inno Setup."
        }
        return Resolve-InnoCompiler
    }

    throw "Inno Setup compiler (ISCC.exe) was not found. Install it, or rerun with -InstallInno."
}

function Get-RidForArch {
    param([string]$Architecture)
    if ($Architecture -eq "arm64") {
        return "win-arm64"
    }
    return "win-x64"
}

function Test-AppxSignatureFile {
    param([Parameter(Mandatory = $true)][string]$PackagePath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        return [bool]($archive.Entries | Where-Object { $_.FullName -eq "AppxSignature.p7x" } | Select-Object -First 1)
    }
    finally {
        $archive.Dispose()
    }
}

function Test-AppxArchiveEntry {
    param(
        [Parameter(Mandatory = $true)][string]$PackagePath,
        [Parameter(Mandatory = $true)][string]$EntryName
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        return [bool]($archive.Entries | Where-Object { $_.FullName -eq $EntryName } | Select-Object -First 1)
    }
    finally {
        $archive.Dispose()
    }
}

function Assert-SignedPackageIdentity {
    param([Parameter(Mandatory = $true)][string]$PackagePath)

    if (-not (Test-AppxSignatureFile -PackagePath $PackagePath)) {
        throw "Package identity MSIX is missing AppxSignature.p7x: $PackagePath"
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $PackagePath
    if ($signature.Status -eq "NotSigned" -or -not $signature.SignerCertificate) {
        throw "Package identity MSIX is not signed: $PackagePath"
    }

    if ($signature.Status -ne "Valid") {
        Write-Warning "Package identity MSIX Authenticode status is $($signature.Status). The installer can still be built, but target machines must trust the signer certificate."
    }

    foreach ($entryName in @(
        "resources.pri",
        "Microsoft.UI.Xaml.Controls.pri",
        "Microsoft.WindowsAppRuntime.pri",
        "WinUIEx.pri"
    )) {
        if (-not (Test-AppxArchiveEntry -PackagePath $PackagePath -EntryName $entryName)) {
            throw "Package identity MSIX is missing required resource map ${entryName}: $PackagePath"
        }
    }
}

function Publish-ArchitecturePayload {
    param(
        [string]$Architecture,
        [string]$RuntimeIdentifier,
        [string]$PublishVersion,
        [string]$PackageIdentityVersion
    )

    $publishDir = Join-Path $repoRoot "publish-local-$Architecture"
    $setupPublishDir = Join-Path $repoRoot "publish-local-setup-$Architecture"

    Write-Step "Publishing $Architecture payload"
    Remove-Item -LiteralPath $publishDir, $setupPublishDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $publishDir | Out-Null

    $trayPublishArgs = @(
        ".\src\OpenClaw.Tray.WinUI\OpenClaw.Tray.WinUI.csproj",
        "-c", $Configuration,
        "-r", $RuntimeIdentifier,
        "--self-contained",
        "-o", $publishDir,
        "-v:minimal",
        "-nr:false"
    )
    if ($PublishVersion) {
        $trayPublishArgs += "-p:Version=$PublishVersion"
    }

    dotnet publish @trayPublishArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Tray publish failed for $Architecture."
    }

    $setupPublishArgs = @(
        ".\src\OpenClaw.SetupEngine.UI\OpenClaw.SetupEngine.UI.csproj",
        "-c", $Configuration,
        "-r", $RuntimeIdentifier,
        "--self-contained",
        "-o", $setupPublishDir,
        "-v:minimal",
        "-nr:false"
    )
    if ($PublishVersion) {
        $setupPublishArgs += "-p:Version=$PublishVersion"
    }

    dotnet publish @setupPublishArgs
    if ($LASTEXITCODE -ne 0) {
        throw "SetupEngine.UI publish failed for $Architecture."
    }

    $setupDest = Join-Path $publishDir "SetupEngine"
    New-Item -ItemType Directory -Path $setupDest -Force | Out-Null
    Copy-Item -Path (Join-Path $setupPublishDir "*") -Destination $setupDest -Recurse -Force

    Write-Step "Building $Architecture package identity"
    $packageIdentityArgs = @(
        "-OutputPath", (Join-Path $publishDir "OpenClaw.PackageIdentity.msix"),
        "-Version", $PackageIdentityVersion,
        "-PayloadRoot", $publishDir,
        "-Sign"
    )
    if ($PackageIdentitySigningThumbprint) {
        $packageIdentityArgs += @("-CertificateThumbprint", $PackageIdentitySigningThumbprint)
    }
    & (Join-Path $PSScriptRoot "build-package-identity.ps1") @packageIdentityArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Package identity build failed for $Architecture."
    }
}

function Assert-PayloadReady {
    param([string]$Architecture)

    $publishDir = Join-Path $repoRoot "publish-local-$Architecture"
    $trayExe = Join-Path $publishDir "OpenClaw.Tray.WinUI.exe"
    $trayPri = Join-Path $publishDir "OpenClaw.Tray.WinUI.pri"
    $trayXbf = Join-Path $publishDir "Windows\TrayMenuWindow.xbf"
    $setupExe = Join-Path $publishDir "SetupEngine\OpenClaw.SetupEngine.UI.exe"
    $identityPackage = Join-Path $publishDir "OpenClaw.PackageIdentity.msix"

    if (-not (Test-Path -LiteralPath $trayExe)) {
        throw "Missing tray payload at $trayExe. Rerun without -NoPublish."
    }
    if (-not (Test-Path -LiteralPath $trayPri)) {
        throw "Missing tray WinUI PRI at $trayPri. Rerun without -NoPublish."
    }
    if (-not (Test-Path -LiteralPath $trayXbf)) {
        throw "Missing tray WinUI XBF at $trayXbf. Rerun without -NoPublish."
    }

    if (-not (Test-Path -LiteralPath $setupExe)) {
        throw "Missing setup payload at $setupExe. Rerun without -NoPublish."
    }

    if (-not (Test-Path -LiteralPath $identityPackage)) {
        throw "Missing package identity payload at $identityPackage. Rerun without -NoPublish."
    }
    Assert-SignedPackageIdentity -PackagePath $identityPackage

    return $publishDir
}

function Invoke-InnoCompiler {
    param(
        [string]$InnoCompiler,
        [string]$Architecture,
        [string]$PublishDir,
        [string]$InstallerVersion
    )

    Write-Step "Compiling $Architecture installer"

    $args = @(
        "/DMyAppVersion=$InstallerVersion",
        "/DMyAppArch=$Architecture",
        "/Dpublish=$PublishDir"
    )

    if ($Fast) {
        $args += "/DMyCompression=zip"
        $args += "/DMySolidCompression=no"
    }

    $args += ".\installer.iss"

    & $InnoCompiler @args
    if ($LASTEXITCODE -ne 0) {
        throw "ISCC failed for $Architecture."
    }
}

$versionWasProvided = $PSBoundParameters.ContainsKey("Version")

if (-not $Version) {
    $versionScript = Join-Path $PSScriptRoot "Get-OpenClawVersion.ps1"
    $Version = & $versionScript -Variable SemVer
}
$packageIdentityVersion = if ($versionWasProvided) {
    $Version
}
else {
    $versionScript = Join-Path $PSScriptRoot "Get-OpenClawVersion.ps1"
    & $versionScript -Variable AssemblySemFileVer -NoRestore
}

if (-not $Version) {
    throw "Could not determine a version. Pass -Version explicitly."
}
if (-not $packageIdentityVersion) {
    throw "Could not determine a package identity version. Pass -Version explicitly."
}

$iscc = Resolve-InnoCompiler
$architectures = if ($Arch -eq "All") { @("x64", "arm64") } else { @($Arch) }

Write-Step "Using ISCC: $iscc"
Write-Host "Version: $Version"
Write-Host "Configuration: $Configuration"
Write-Host "Fast compression: $($Fast.IsPresent)"
Write-Host "No publish: $($NoPublish.IsPresent)"
Write-Host "Package identity signing: required"

foreach ($architecture in $architectures) {
    $rid = Get-RidForArch $architecture
    if (-not $NoPublish) {
        $publishVersion = if ($versionWasProvided) { $Version } else { $null }
        Publish-ArchitecturePayload -Architecture $architecture -RuntimeIdentifier $rid -PublishVersion $publishVersion -PackageIdentityVersion $packageIdentityVersion
    }

    $payload = Assert-PayloadReady $architecture
    Invoke-InnoCompiler -InnoCompiler $iscc -Architecture $architecture -PublishDir $payload -InstallerVersion $Version
}

Write-Step "Built installers"
Get-ChildItem -Path (Join-Path $repoRoot "Output\OpenClawCompanion-Setup-*.exe") |
    Sort-Object Name |
    ForEach-Object {
        "{0}`t{1:N2} MB`t{2}" -f $_.FullName, ($_.Length / 1MB), $_.LastWriteTime
    }
