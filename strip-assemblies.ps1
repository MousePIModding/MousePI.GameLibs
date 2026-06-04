[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $GameExePath,

    [Parameter(Position = 1)]
    [string] $UnityVersion,

    [switch] $VersionOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Add all the assemblies you want to publicize in this list.
$ToPublicize = @(
    "Assembly-CSharp.dll",
    "Mouse.dll",
    "Mouse.PackedSprites.dll"
)

# Add all the assemblies you want to copy as-is to the package in this list.
$DontTouch = @()

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$NStripPath = Join-Path $ScriptRoot "tools\NStrip.exe"
$AssemblyHollowerProjectPath = Join-Path $ScriptRoot "tools\AssemblyHollower\AssemblyHollower.csproj"
$OutPath = Join-Path $ScriptRoot "package\lib"
$LibrariesBaseUrl = "https://unity.bepinex.dev/libraries"
$CorlibsBaseUrl = "https://unity.bepinex.dev/corlibs"

function Normalize-UnityVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Version
    )

    $trimmed = $Version.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        throw "Unity version was empty."
    }

    if ($trimmed -match "([0-9]+\.[0-9]+\.[0-9]+)f[0-9]+") {
        return $Matches[1]
    }

    if ($trimmed -match "([0-9]+\.[0-9]+\.[0-9]+(?:[abp][0-9]+)?)") {
        return $Matches[1]
    }

    throw "Could not parse Unity version from '$Version'."
}

function Resolve-UnityVersion {
    param(
        [string] $VersionOverride,

        [Parameter(Mandatory = $true)]
        [string] $UnityPlayerPath
    )

    if (-not [string]::IsNullOrWhiteSpace($VersionOverride)) {
        return Normalize-UnityVersion $VersionOverride
    }

    if (-not (Test-Path -LiteralPath $UnityPlayerPath -PathType Leaf)) {
        throw "Could not find UnityPlayer.dll at '$UnityPlayerPath'. Pass the Unity version as the second argument."
    }

    $fileVersionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($UnityPlayerPath)
    $candidates = @($fileVersionInfo.ProductVersion, $fileVersionInfo.FileVersion)

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            try {
                return Normalize-UnityVersion $candidate
            }
            catch {
                Write-Verbose "Could not parse Unity version candidate '$candidate': $($_.Exception.Message)"
            }
        }
    }

    throw "Could not derive Unity version from '$UnityPlayerPath'. Pass the Unity version as the second argument."
}

function Invoke-NStrip {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    & $NStripPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "NStrip failed with exit code $LASTEXITCODE. Arguments: $($Arguments -join ' ')"
    }
}

function Invoke-AssemblyHollower {
    param(
        [Parameter(Mandatory = $true)]
        [string] $AssemblyPath
    )

    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw "Could not find the dotnet SDK/runtime on PATH. It is required for the final AssemblyHollower pass."
    }

    & dotnet run --project $AssemblyHollowerProjectPath --configuration Release --verbosity quiet -- $AssemblyPath
    if ($LASTEXITCODE -ne 0) {
        throw "AssemblyHollower failed with exit code $LASTEXITCODE."
    }
}

function Download-Archive {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $BaseUrl,

        [Parameter(Mandatory = $true)]
        [string] $Version,

        [Parameter(Mandatory = $true)]
        [string] $DestinationPath
    )

    $uri = "$BaseUrl/$Version.zip"
    Write-Host "Downloading $Name reference archive: $uri"

    try {
        Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $DestinationPath
    }
    catch {
        throw "Could not download exact Unity $Name archive '$uri'. Check the Unity version or BepInEx archive availability."
    }

    if (-not (Test-Path -LiteralPath $DestinationPath -PathType Leaf)) {
        throw "Download did not create '$DestinationPath'."
    }
}

function Add-ArchiveEntries {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.Dictionary[string, object]] $Entries,

        [Parameter(Mandatory = $true)]
        [string] $ZipPath,

        [Parameter(Mandatory = $true)]
        [string] $SourceName
    )

    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $archive.Entries) {
            $fileName = [System.IO.Path]::GetFileName($entry.FullName)
            if ([string]::IsNullOrWhiteSpace($fileName) -or -not $fileName.EndsWith(".dll", [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            if ($Entries.ContainsKey($fileName)) {
                Write-Warning "Reference assembly '$fileName' exists in multiple archives. Keeping '$($Entries[$fileName].SourceName)' and ignoring '$SourceName'."
                continue
            }

            $Entries.Add($fileName, [PSCustomObject]@{
                ZipPath = $ZipPath
                EntryName = $entry.FullName
                SourceName = $SourceName
            })
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Extract-ArchiveEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ZipPath,

        [Parameter(Mandatory = $true)]
        [string] $EntryName,

        [Parameter(Mandatory = $true)]
        [string] $DestinationPath
    )

    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entry = $archive.GetEntry($EntryName)
        if ($null -eq $entry) {
            throw "Archive '$ZipPath' no longer contains '$EntryName'."
        }

        if (Test-Path -LiteralPath $DestinationPath) {
            Remove-Item -LiteralPath $DestinationPath -Force
        }

        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $DestinationPath)
    }
    finally {
        $archive.Dispose()
    }
}

function Copy-ManagedAssembliesToSource {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ManagedPath,

        [Parameter(Mandatory = $true)]
        [string] $SourcePath,

        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.Dictionary[string, object]] $ReferenceEntries
    )

    $gameDlls = @(Get-ChildItem -LiteralPath $ManagedPath -Filter "*.dll" -File)
    if ($gameDlls.Count -eq 0) {
        throw "No DLLs found in '$ManagedPath'."
    }

    $substitutedCount = 0
    foreach ($gameDll in $gameDlls) {
        $destinationPath = Join-Path $SourcePath $gameDll.Name
        $referenceEntry = $null

        if ($ReferenceEntries.TryGetValue($gameDll.Name, [ref] $referenceEntry)) {
            Extract-ArchiveEntry -ZipPath $referenceEntry.ZipPath -EntryName $referenceEntry.EntryName -DestinationPath $destinationPath
            $substitutedCount++
        }
        else {
            Copy-Item -LiteralPath $gameDll.FullName -Destination $destinationPath
        }
    }

    Write-Host "Prepared $($gameDlls.Count) assemblies. Substituted $substitutedCount Unity/corlib reference assemblies before hollowing."
}

if (-not (Test-Path -LiteralPath $NStripPath -PathType Leaf)) {
    throw "Could not find NStrip at '$NStripPath'."
}

if (-not (Test-Path -LiteralPath $AssemblyHollowerProjectPath -PathType Leaf)) {
    throw "Could not find AssemblyHollower project at '$AssemblyHollowerProjectPath'."
}

if (-not (Test-Path -LiteralPath $GameExePath -PathType Leaf)) {
    throw "Could not find game exe '$GameExePath'."
}

$resolvedExePath = (Resolve-Path -LiteralPath $GameExePath).ProviderPath
$gameRoot = Split-Path -Parent $resolvedExePath
$gameName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedExePath)
$managedPath = Join-Path $gameRoot "$($gameName)_Data\Managed"
$unityPlayerPath = Join-Path $gameRoot "UnityPlayer.dll"

if (-not (Test-Path -LiteralPath $managedPath -PathType Container)) {
    throw "Could not find managed assembly folder '$managedPath'."
}

$resolvedUnityVersion = Resolve-UnityVersion -VersionOverride $UnityVersion -UnityPlayerPath $unityPlayerPath
Write-Host "Game exe: $resolvedExePath"
Write-Host "Managed assemblies: $managedPath"
Write-Host "Unity version: $resolvedUnityVersion"

if ($VersionOnly) {
    return
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "MousePI.GameLibs.$([System.Guid]::NewGuid().ToString('N'))"
$sourcePath = Join-Path $tempRoot "source"
$librariesZipPath = Join-Path $tempRoot "unity-libraries.zip"
$corlibsZipPath = Join-Path $tempRoot "unity-corlibs.zip"

try {
    New-Item -ItemType Directory -Path $sourcePath -Force | Out-Null

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    Download-Archive -Name "engine libraries" -BaseUrl $LibrariesBaseUrl -Version $resolvedUnityVersion -DestinationPath $librariesZipPath
    Download-Archive -Name "corlibs" -BaseUrl $CorlibsBaseUrl -Version $resolvedUnityVersion -DestinationPath $corlibsZipPath

    $referenceEntries = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    Add-ArchiveEntries -Entries $referenceEntries -ZipPath $librariesZipPath -SourceName "Unity engine libraries"
    Add-ArchiveEntries -Entries $referenceEntries -ZipPath $corlibsZipPath -SourceName "Unity corlibs"

    Copy-ManagedAssembliesToSource -ManagedPath $managedPath -SourcePath $sourcePath -ReferenceEntries $referenceEntries

    New-Item -ItemType Directory -Path $OutPath -Force | Out-Null
    Get-ChildItem -LiteralPath $OutPath -Filter "*.dll" -File | Remove-Item -Force

    Write-Host "Hollowing all assemblies into '$OutPath'."
    Invoke-NStrip -Arguments @($sourcePath, "-o", $OutPath)

    foreach ($assembly in $ToPublicize) {
        $assemblySourcePath = Join-Path $sourcePath $assembly
        $assemblyOutPath = Join-Path $OutPath $assembly
        if (-not (Test-Path -LiteralPath $assemblySourcePath -PathType Leaf)) {
            throw "Configured publicized assembly '$assembly' was not found in '$managedPath'."
        }

        Write-Host "Hollowing and publicizing '$assembly'."
        Invoke-NStrip -Arguments @($assemblySourcePath, "-o", $assemblyOutPath, "-cg", "-p", "--cg-exclude-events")
    }

    Write-Host "Hollowing any method bodies missed by NStrip."
    Invoke-AssemblyHollower -AssemblyPath $OutPath

    foreach ($assembly in $DontTouch) {
        $assemblySourcePath = Join-Path $managedPath $assembly
        $assemblyOutPath = Join-Path $OutPath $assembly
        if (-not (Test-Path -LiteralPath $assemblySourcePath -PathType Leaf)) {
            throw "Configured untouched assembly '$assembly' was not found in '$managedPath'."
        }

        Write-Host "Copying untouched assembly '$assembly'."
        Copy-Item -LiteralPath $assemblySourcePath -Destination $assemblyOutPath -Force
    }

    Write-Host "Finished. Hollowed assemblies are in '$OutPath'."
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
