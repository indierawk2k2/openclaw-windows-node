<#
.SYNOPSIS
    Builds the OpenClaw sparse package identity MSIX.

.DESCRIPTION
    Stages a package-with-external-location manifest from the WinUI package
    manifest and packs it into a small MSIX. CI signs the release package with
    Azure Artifact Signing; local installer builds can pass -Sign to sign with
    an OpenClaw code-signing certificate from the Windows certificate store.
#>

[CmdletBinding()]
param(
    [string]$ManifestPath,

    [string]$OutputPath,

    [string]$Version,

    [string]$PayloadRoot,

    [string]$StagingRoot,

    [string]$MakeAppxPath,

    [string]$MakePriPath,

    [string]$SignToolPath,

    [string]$CertificateThumbprint = $env:OPENCLAW_PACKAGE_IDENTITY_SIGNING_THUMBPRINT,

    [string]$TimestampUrl = "http://timestamp.acs.microsoft.com",

    [switch]$Sign,

    [switch]$SkipPack
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if (-not $ManifestPath) {
    $ManifestPath = Join-Path $repoRoot "src\OpenClaw.Tray.WinUI\Package.appxmanifest"
}
if (-not $OutputPath) {
    $OutputPath = Join-Path $repoRoot "publish\OpenClaw.PackageIdentity.msix"
}
if (-not $StagingRoot) {
    $StagingRoot = Join-Path $repoRoot "obj\PackageIdentity"
}

function ConvertTo-AppxVersion {
    param([Parameter(Mandatory = $true)][string]$InputVersion)

    $normalized = ($InputVersion -replace '^v', '') -replace '[-+].*$', ''
    $parts = @($normalized.Split('.', [System.StringSplitOptions]::RemoveEmptyEntries))
    if ($parts.Count -gt 4 -or $parts.Count -lt 1) {
        throw "Version '$InputVersion' cannot be converted to an MSIX four-part version."
    }

    while ($parts.Count -lt 4) {
        $parts += "0"
    }

    foreach ($part in $parts) {
        if ($part -notmatch '^\d+$') {
            throw "Version '$InputVersion' contains a non-numeric MSIX version component."
        }
    }

    $parts -join "."
}

function Resolve-FromRepositoryRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Resolve-WindowsSdkTool {
    param([Parameter(Mandatory = $true)][string]$ToolName)

    $command = Get-Command $ToolName -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $sdkBinRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    if (Test-Path -LiteralPath $sdkBinRoot) {
        $candidate = Get-ChildItem -LiteralPath $sdkBinRoot -Directory |
            Sort-Object Name -Descending |
            ForEach-Object {
                @(
                    Join-Path $_.FullName "x64\$ToolName"
                    Join-Path $_.FullName "arm64\$ToolName"
                    Join-Path $_.FullName "x86\$ToolName"
                )
            } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1

        if ($candidate) {
            return $candidate
        }
    }

    throw "$ToolName was not found. Install the Windows SDK or add it to PATH."
}

function Resolve-CodeSigningCertificate {
    param(
        [Parameter(Mandatory = $true)][string]$PublisherSubject,
        [string]$Thumbprint
    )

    $normalizedThumbprint = if ($Thumbprint) { $Thumbprint -replace '\s', '' } else { "" }
    $stores = @(
        @{ Path = "Cert:\CurrentUser\My"; UseMachineStore = $false },
        @{ Path = "Cert:\LocalMachine\My"; UseMachineStore = $true }
    )

    $matches = foreach ($store in $stores) {
        Get-ChildItem -Path $store.Path -CodeSigningCert -ErrorAction SilentlyContinue |
            Where-Object {
                $_.HasPrivateKey -and
                $_.NotAfter -gt (Get-Date) -and
                (
                    ($normalizedThumbprint -and $_.Thumbprint -eq $normalizedThumbprint) -or
                    (-not $normalizedThumbprint -and $_.Subject -eq $PublisherSubject)
                )
            } |
            ForEach-Object {
                [pscustomobject]@{
                    Certificate = $_
                    UseMachineStore = $store.UseMachineStore
                }
            }
    }

    $selected = $matches | Sort-Object { $_.Certificate.NotAfter } -Descending | Select-Object -First 1
    if (-not $selected) {
        $selector = if ($normalizedThumbprint) {
            "thumbprint $normalizedThumbprint"
        }
        else {
            "subject '$PublisherSubject'"
        }
        throw "No code-signing certificate with private key found for $selector in CurrentUser\My or LocalMachine\My."
    }

    return $selected
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

function Assert-PackageIsSigned {
    param([Parameter(Mandatory = $true)][string]$PackagePath)

    if (-not (Test-AppxSignatureFile -PackagePath $PackagePath)) {
        throw "$PackagePath does not contain AppxSignature.p7x."
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $PackagePath
    if ($signature.Status -eq "NotSigned" -or -not $signature.SignerCertificate) {
        throw "$PackagePath is not Authenticode signed."
    }

    if ($signature.Status -ne "Valid") {
        Write-Warning "$PackagePath Authenticode status is $($signature.Status). The package is signed, but trust validation depends on the target machine certificate stores."
    }
}

function Invoke-PackageSigning {
    param(
        [Parameter(Mandatory = $true)][string]$PackagePath,
        [Parameter(Mandatory = $true)][string]$PublisherSubject
    )

    if (-not $SignToolPath) {
        $SignToolPath = Resolve-WindowsSdkTool -ToolName "signtool.exe"
    }

    $cert = Resolve-CodeSigningCertificate -PublisherSubject $PublisherSubject -Thumbprint $CertificateThumbprint
    $args = @("sign")
    if ($cert.UseMachineStore) {
        $args += "/sm"
    }
    $args += @("/sha1", $cert.Certificate.Thumbprint, "/fd", "SHA256")
    if ($TimestampUrl) {
        $args += @("/tr", $TimestampUrl, "/td", "SHA256")
    }
    $args += $PackagePath

    & $SignToolPath @args
    if ($LASTEXITCODE -ne 0) {
        throw "signtool failed with exit code $LASTEXITCODE."
    }

    Assert-PackageIsSigned -PackagePath $PackagePath
    Write-Host "Signed package identity MSIX with $($cert.Certificate.Subject): $PackagePath"
}

function Ensure-NamespaceDeclaration {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlElement]$Element,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$NamespaceUri
    )

    if ($Element.GetAttribute("xmlns:$Prefix") -ne $NamespaceUri) {
        $Element.SetAttribute("xmlns:$Prefix", $NamespaceUri)
    }

    $ignorable = $Element.GetAttribute("IgnorableNamespaces")
    $names = @($ignorable -split '\s+' | Where-Object { $_ })
    if ($names -notcontains $Prefix) {
        $Element.SetAttribute("IgnorableNamespaces", (($names + $Prefix) -join " "))
    }
}

function Set-NamespaceAttribute {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlElement]$Element,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$LocalName,
        [Parameter(Mandatory = $true)][string]$NamespaceUri,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $attribute = $Element.OwnerDocument.CreateAttribute($Prefix, $LocalName, $NamespaceUri)
    $attribute.Value = $Value
    [void]$Element.Attributes.SetNamedItem($attribute)
}

function Add-OrUpdateElementText {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlDocument]$Document,
        [Parameter(Mandatory = $true)][System.Xml.XmlElement]$Parent,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$LocalName,
        [Parameter(Mandatory = $true)][string]$NamespaceUri,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $existing = $Parent.ChildNodes |
        Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element -and $_.LocalName -eq $LocalName -and $_.NamespaceURI -eq $NamespaceUri } |
        Select-Object -First 1

    if (-not $existing) {
        $existing = $Document.CreateElement($Prefix, $LocalName, $NamespaceUri)
        [void]$Parent.AppendChild($existing)
    }

    $existing.InnerText = $Value
}

function Ensure-RestrictedCapability {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlDocument]$Document,
        [Parameter(Mandatory = $true)][System.Xml.XmlElement]$Capabilities,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$NamespaceUri
    )

    $existing = $Capabilities.ChildNodes |
        Where-Object {
            $_.NodeType -eq [System.Xml.XmlNodeType]::Element -and
            $_.LocalName -eq "Capability" -and
            $_.NamespaceURI -eq $NamespaceUri -and
            $_.GetAttribute("Name") -eq $Name
        } |
        Select-Object -First 1

    if ($existing) {
        [void]$Capabilities.RemoveChild($existing)
        $capability = $existing
    }
    else {
        $capability = $Document.CreateElement("rescap", "Capability", $NamespaceUri)
        $capability.SetAttribute("Name", $Name)
    }

    $firstDeviceCapability = $Capabilities.ChildNodes |
        Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element -and $_.LocalName -eq "DeviceCapability" } |
        Select-Object -First 1

    if ($firstDeviceCapability) {
        [void]$Capabilities.InsertBefore($capability, $firstDeviceCapability)
    }
    else {
        [void]$Capabilities.AppendChild($capability)
    }
}

function Copy-ManifestAsset {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )

    $normalizedRelativePath = $RelativePath -replace '/', '\'
    $sourcePath = Join-Path $SourceRoot $normalizedRelativePath
    $sourceDirectory = Split-Path -Parent $sourcePath
    $fileName = [System.IO.Path]::GetFileName($sourcePath)
    $filePrefix = [System.IO.Path]::GetFileNameWithoutExtension($sourcePath)
    $extension = [System.IO.Path]::GetExtension($sourcePath)
    $relativeDirectory = Split-Path -Parent $normalizedRelativePath

    $matches = @(Get-ChildItem -LiteralPath $sourceDirectory -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -eq $fileName -or
            ($_.Name.StartsWith($filePrefix, [System.StringComparison]::OrdinalIgnoreCase) -and $_.Extension -eq $extension)
        })
    if ($matches.Count -eq 0) {
        throw "Manifest asset was not found: $RelativePath"
    }

    foreach ($match in $matches) {
        $targetDirectory = if ($relativeDirectory) {
            Join-Path $DestinationRoot $relativeDirectory
        }
        else {
            $DestinationRoot
        }
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
        Copy-Item -LiteralPath $match.FullName -Destination (Join-Path $targetDirectory $match.Name) -Force
    }
}

function Resolve-PayloadRuntimeIdentifier {
    param([Parameter(Mandatory = $true)][string]$SourceRoot)

    $depsPath = Join-Path $SourceRoot "OpenClaw.Tray.WinUI.deps.json"
    if (-not (Test-Path -LiteralPath $depsPath)) {
        return $null
    }

    $deps = Get-Content -LiteralPath $depsPath -Raw | ConvertFrom-Json
    $runtimeTargetName = if ($deps.runtimeTarget) { [string]$deps.runtimeTarget.name } else { "" }
    if ($runtimeTargetName -match '/(?<rid>win-(x64|arm64))$') {
        return $Matches.rid
    }

    throw "Could not determine RuntimeIdentifier from $depsPath."
}

function Resolve-PriConfigPath {
    param([Parameter(Mandatory = $true)][string]$RuntimeIdentifier)

    $objRoot = Join-Path $repoRoot "src\OpenClaw.Tray.WinUI\obj"
    if (-not (Test-Path -LiteralPath $objRoot)) {
        return $null
    }

    Get-ChildItem -LiteralPath $objRoot -Recurse -File -Filter "priconfig.xml" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like "*\$RuntimeIdentifier\priconfig.xml" } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
}

function New-PackageResourceIndex {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [Parameter(Mandatory = $true)][string]$StagedManifestPath
    )

    $runtimeIdentifier = Resolve-PayloadRuntimeIdentifier -SourceRoot $SourceRoot
    if (-not $runtimeIdentifier) {
        return $false
    }

    $priConfig = Resolve-PriConfigPath -RuntimeIdentifier $runtimeIdentifier
    if (-not $priConfig) {
        return $false
    }

    $resolvedMakePriPath = $MakePriPath
    if (-not $resolvedMakePriPath) {
        $resolvedMakePriPath = Resolve-WindowsSdkTool -ToolName "makepri.exe"
    }

    $projectRoot = Join-Path $repoRoot "src\OpenClaw.Tray.WinUI"
    $resourcesPri = Join-Path $DestinationRoot "resources.pri"
    Remove-Item -LiteralPath $resourcesPri -Force -ErrorAction SilentlyContinue

    Push-Location $projectRoot
    try {
        & $resolvedMakePriPath new /pr $projectRoot /cf $priConfig.FullName /mn $StagedManifestPath /of $resourcesPri /o
        if ($LASTEXITCODE -ne 0) {
            throw "makepri failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }

    Write-Host "Generated package identity resource map from $($priConfig.FullName): resources.pri"
    return $true
}

function Copy-PayloadResourceIndexes {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [Parameter(Mandatory = $true)][string]$StagedManifestPath
    )

    $sourceFullPath = Resolve-FromRepositoryRoot -Path $SourceRoot
    if (-not (Test-Path -LiteralPath $sourceFullPath)) {
        throw "Package identity payload root not found: $SourceRoot"
    }

    $priFiles = @(Get-ChildItem -LiteralPath $sourceFullPath -File -Filter "*.pri" -ErrorAction SilentlyContinue)
    if ($priFiles.Count -eq 0) {
        throw "Package identity payload root does not contain root PRI resource maps: $sourceFullPath"
    }

    $copied = New-Object System.Collections.Generic.List[string]
    foreach ($priFile in $priFiles) {
        if ($priFile.Name -ieq "OpenClaw.Tray.WinUI.pri" -or $priFile.Name -ieq "resources.pri") {
            continue
        }

        Copy-Item -LiteralPath $priFile.FullName -Destination (Join-Path $DestinationRoot $priFile.Name) -Force
        [void]$copied.Add($priFile.Name)
    }

    if (-not (New-PackageResourceIndex -SourceRoot $sourceFullPath -DestinationRoot $DestinationRoot -StagedManifestPath $StagedManifestPath)) {
        $resourcesPri = $priFiles | Where-Object { $_.Name -ieq "resources.pri" } | Select-Object -First 1
        if (-not $resourcesPri) {
            throw "Package identity payload root must contain generated resources.pri or OpenClaw.Tray.WinUI.deps.json plus MSBuild PRI metadata: $sourceFullPath"
        }

        Copy-Item -LiteralPath $resourcesPri.FullName -Destination (Join-Path $DestinationRoot "resources.pri") -Force
        [void]$copied.Add("resources.pri")
    }

    foreach ($requiredEntry in @("resources.pri", "Microsoft.UI.Xaml.Controls.pri", "Microsoft.WindowsAppRuntime.pri")) {
        if (-not (Test-Path -LiteralPath (Join-Path $DestinationRoot $requiredEntry))) {
            throw "Package identity payload root did not provide required resource map: $requiredEntry"
        }
    }

    Copy-Item -LiteralPath (Join-Path $DestinationRoot "resources.pri") -Destination (Join-Path $sourceFullPath "resources.pri") -Force
    Write-Host "Staged package identity resource maps: $(($copied | Sort-Object -Unique) -join ', ')"
    Write-Host "Staged external-location package resource map: $(Join-Path $sourceFullPath "resources.pri")"
}

$manifestFullPath = Resolve-FromRepositoryRoot -Path $ManifestPath
if (-not (Test-Path -LiteralPath $manifestFullPath)) {
    throw "Package manifest not found: $ManifestPath"
}

if (-not $Version) {
    $versionScript = Join-Path $PSScriptRoot "Get-OpenClawVersion.ps1"
    $Version = & $versionScript -Variable AssemblySemFileVer
}

$appxVersion = ConvertTo-AppxVersion -InputVersion $Version
$manifestPathResolved = (Resolve-Path -LiteralPath $manifestFullPath).Path
$sourceManifestDir = Split-Path -Parent $manifestPathResolved
$outputFullPath = Resolve-FromRepositoryRoot -Path $OutputPath
$stagingFullPath = Resolve-FromRepositoryRoot -Path $StagingRoot
if (-not $PayloadRoot) {
    $payloadRootCandidate = Split-Path -Parent $outputFullPath
    if (Test-Path -LiteralPath $payloadRootCandidate) {
        $PayloadRoot = $payloadRootCandidate
    }
}

Remove-Item -LiteralPath $stagingFullPath -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $stagingFullPath | Out-Null

$foundationNs = "http://schemas.microsoft.com/appx/manifest/foundation/windows10"
$uapNs = "http://schemas.microsoft.com/appx/manifest/uap/windows10"
$uap10Ns = "http://schemas.microsoft.com/appx/manifest/uap/windows10/10"
$rescapNs = "http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"

$doc = New-Object System.Xml.XmlDocument
$doc.PreserveWhitespace = $true
$doc.Load($manifestPathResolved)

$package = $doc.DocumentElement
Ensure-NamespaceDeclaration -Element $package -Prefix "uap10" -NamespaceUri $uap10Ns
Ensure-NamespaceDeclaration -Element $package -Prefix "rescap" -NamespaceUri $rescapNs

$ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
$ns.AddNamespace("appx", $foundationNs)
$ns.AddNamespace("uap", $uapNs)
$ns.AddNamespace("uap10", $uap10Ns)
$ns.AddNamespace("rescap", $rescapNs)

$identity = [System.Xml.XmlElement]$doc.SelectSingleNode("/appx:Package/appx:Identity", $ns)
if (-not $identity) {
    throw "Package manifest is missing Identity."
}
$identity.SetAttribute("Version", $appxVersion)
$identity.SetAttribute("ProcessorArchitecture", "neutral")

$properties = [System.Xml.XmlElement]$doc.SelectSingleNode("/appx:Package/appx:Properties", $ns)
if (-not $properties) {
    throw "Package manifest is missing Properties."
}
Add-OrUpdateElementText -Document $doc -Parent $properties -Prefix "uap10" -LocalName "AllowExternalContent" -NamespaceUri $uap10Ns -Value "true"

$resources = [System.Xml.XmlElement]$doc.SelectSingleNode("/appx:Package/appx:Resources", $ns)
if (-not $resources) {
    $resources = $doc.CreateElement("Resources", $foundationNs)
    [void]$package.InsertAfter($resources, $properties)
}
$resourceLanguages = @($resources.ChildNodes |
    Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element -and $_.LocalName -eq "Resource" })
if ($resourceLanguages.Count -eq 0) {
    $resource = $doc.CreateElement("Resource", $foundationNs)
    $resource.SetAttribute("Language", "en-US")
    [void]$resources.AppendChild($resource)
}
else {
    foreach ($resource in $resourceLanguages) {
        if ($resource.GetAttribute("Language") -eq "x-generate") {
            $resource.SetAttribute("Language", "en-US")
        }
    }
}

$targetDeviceFamily = [System.Xml.XmlElement]$doc.SelectSingleNode("/appx:Package/appx:Dependencies/appx:TargetDeviceFamily[@Name='Windows.Desktop']", $ns)
if (-not $targetDeviceFamily) {
    throw "Package manifest is missing the Windows.Desktop TargetDeviceFamily."
}
if ([version]$targetDeviceFamily.GetAttribute("MinVersion") -lt [version]"10.0.19041.0") {
    $targetDeviceFamily.SetAttribute("MinVersion", "10.0.19041.0")
}
$application = [System.Xml.XmlElement]$doc.SelectSingleNode("/appx:Package/appx:Applications/appx:Application[@Id='App']", $ns)
if (-not $application) {
    throw "Package manifest is missing Application Id='App'."
}
$application.SetAttribute("Executable", "OpenClaw.Tray.WinUI.exe")
$application.RemoveAttribute("EntryPoint")
Set-NamespaceAttribute -Element $application -Prefix "uap10" -LocalName "TrustLevel" -NamespaceUri $uap10Ns -Value "mediumIL"
Set-NamespaceAttribute -Element $application -Prefix "uap10" -LocalName "RuntimeBehavior" -NamespaceUri $uap10Ns -Value "win32App"

$visualElements = [System.Xml.XmlElement]$application.SelectSingleNode("uap:VisualElements", $ns)
if (-not $visualElements) {
    throw "Application Id='App' is missing uap:VisualElements."
}
$visualElements.SetAttribute("AppListEntry", "none")

$capabilities = [System.Xml.XmlElement]$doc.SelectSingleNode("/appx:Package/appx:Capabilities", $ns)
if (-not $capabilities) {
    $capabilities = $doc.CreateElement("Capabilities", $foundationNs)
    [void]$package.AppendChild($capabilities)
}
Ensure-RestrictedCapability -Document $doc -Capabilities $capabilities -Name "runFullTrust" -NamespaceUri $rescapNs
Ensure-RestrictedCapability -Document $doc -Capabilities $capabilities -Name "unvirtualizedResources" -NamespaceUri $rescapNs

$assetAttributeNames = @(
    "Logo",
    "Square44x44Logo",
    "Square150x150Logo",
    "Square310x310Logo",
    "Square71x71Logo",
    "Wide310x150Logo",
    "Image"
)
$assetPaths = @($doc.SelectNodes("//@*", $ns) |
    Where-Object { $assetAttributeNames -contains $_.LocalName -and $_.Value -match '\.(png|jpg|jpeg)$' } |
    ForEach-Object { $_.Value }) +
    @($doc.SelectNodes("/appx:Package/appx:Properties/appx:Logo", $ns) |
    ForEach-Object { $_.InnerText })
$assetPaths = $assetPaths | Sort-Object -Unique

foreach ($assetPath in $assetPaths) {
    Copy-ManifestAsset -RelativePath $assetPath -SourceRoot $sourceManifestDir -DestinationRoot $stagingFullPath
}

$stagedManifestPath = Join-Path $stagingFullPath "AppxManifest.xml"
$doc.Save($stagedManifestPath)
Write-Host "Staged package identity manifest: $stagedManifestPath"

if ($PayloadRoot) {
    Copy-PayloadResourceIndexes -SourceRoot $PayloadRoot -DestinationRoot $stagingFullPath -StagedManifestPath $stagedManifestPath
}
else {
    Write-Warning "No payload root was provided; package identity resource maps were not staged."
}

if ($SkipPack) {
    return
}

New-Item -ItemType Directory -Path (Split-Path -Parent $outputFullPath) -Force | Out-Null
Remove-Item -LiteralPath $outputFullPath -Force -ErrorAction SilentlyContinue

if (-not $MakeAppxPath) {
    $MakeAppxPath = Resolve-WindowsSdkTool -ToolName "makeappx.exe"
}

& $MakeAppxPath pack /d $stagingFullPath /p $outputFullPath /nv /o
if ($LASTEXITCODE -ne 0) {
    throw "makeappx failed with exit code $LASTEXITCODE."
}

Write-Host "Built package identity MSIX: $outputFullPath"
if ($Sign) {
    Invoke-PackageSigning -PackagePath $outputFullPath -PublisherSubject $identity.GetAttribute("Publisher")
}
