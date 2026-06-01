<#
.SYNOPSIS
    Registers or unregisters the OpenClaw package-with-external-location identity.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Register", "Unregister")]
    [string]$Mode,

    [string]$PackagePath,

    [string]$ExternalLocation,

    [Parameter(Mandatory = $true)]
    [string]$PackageName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$minimumExternalLocationBuild = 19041
if ([Environment]::OSVersion.Version.Build -lt $minimumExternalLocationBuild) {
    Write-Host "Skipping package identity $Mode; Windows build $([Environment]::OSVersion.Version.Build) is below $minimumExternalLocationBuild."
    exit 0
}

if ($Mode -eq "Register") {
    if (-not $PackagePath -or -not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
        throw "Package identity MSIX was not found: $PackagePath"
    }
    if (-not $ExternalLocation -or -not (Test-Path -LiteralPath $ExternalLocation -PathType Container)) {
        throw "External location was not found: $ExternalLocation"
    }

    Add-AppxPackage `
        -Path $PackagePath `
        -ExternalLocation $ExternalLocation `
        -ForceApplicationShutdown `
        -ForceUpdateFromAnyVersion

    Write-Host "Registered package identity '$PackageName' from '$PackagePath' with external location '$ExternalLocation'."
    exit 0
}

$packages = @(Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue)
if ($packages.Count -eq 0) {
    Write-Host "Package identity '$PackageName' is not registered for this user."
    exit 0
}

foreach ($package in $packages) {
    Remove-AppxPackage -Package $package.PackageFullName
    Write-Host "Removed package identity '$($package.PackageFullName)'."
}
