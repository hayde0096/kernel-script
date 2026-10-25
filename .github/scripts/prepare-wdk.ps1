<#
.SYNOPSIS
    Locates (or installs) a Windows Driver Kit content root and exports
    WDK_ROOT / WDK_LIB / WDK_VERSION for the ks-driver build.

.DESCRIPTION
    ks-driver/build.rs, when KS_DRIVER_WDK=1, requires

        <WDK_ROOT>\Include\<WDK_VERSION>\km\ntddk.h
        <WDK_ROOT>\Include\<WDK_VERSION>\shared
        <WDK_LIB>\ntoskrnl.lib

    where <WDK_LIB> is <WDK_ROOT>\Lib\<WDK_VERSION>\km\x64.

    This script finds such a kit, installing one when the runner has none:

      1. an already installed kit under -KitsRoot (or %WDK_ROOT%)
      2. `winget install Microsoft.WindowsWDK.10.0.26100`
      3. the public NuGet content packages
         Microsoft.Windows.SDK.CPP, Microsoft.Windows.SDK.CPP.x64 and
         Microsoft.Windows.WDK.x64

    The resulting values are written to $GITHUB_ENV so later steps inherit
    them, and to $GITHUB_STEP_SUMMARY for the run page.

    Nothing here touches the driver source: it only makes the headers and
    kernel import libraries available.
#>
[CmdletBinding()]
param(
    # Kit version prefix to prefer; the workspace is validated against
    # 10.0.26100.0 (see AGENTS.md "Driver Build").
    [string] $PreferredVersion = '10.0.26100',

    # Default WDK install location on a normal Windows machine.
    [string] $KitsRoot = 'C:\Program Files (x86)\Windows Kits\10',

    # Where the NuGet fallback unpacks; defaults to a temp directory.
    [string] $NugetRoot,

    # Target architecture of the kernel import libraries (x64 only for now).
    [string] $Architecture = 'x64'
)

$ErrorActionPreference = 'Stop'

function Write-EnvValue {
    param([string] $Name, [string] $Value)

    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
    if ($env:GITHUB_ENV) {
        [IO.File]::AppendAllText($env:GITHUB_ENV, "$Name=$Value`n")
    }
    Write-Host ("{0,-12}= {1}" -f $Name, $Value)
}

function Add-Summary {
    param([string] $Line)

    if ($env:GITHUB_STEP_SUMMARY) {
        [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, "$Line`n")
    }
}

# Returns @{ Root; Version; Lib } for the first kit that has both the km
# headers and the x64 kernel import libraries, or $null.
function Find-KitContent {
    param(
        [string[]] $Roots,
        [string] $VersionPrefix,
        [switch] $Strict
    )

    foreach ($root in $Roots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        if (-not (Test-Path -LiteralPath $root)) { continue }

        $includeRoot = Join-Path $root 'Include'
        if (-not (Test-Path -LiteralPath $includeRoot)) { continue }

        $candidates = @(Get-ChildItem -LiteralPath $includeRoot -Directory -ErrorAction SilentlyContinue)
        $ordered = @($candidates |
            Where-Object { $_.Name.StartsWith($VersionPrefix) } |
            Sort-Object -Property Name -Descending)
        if (-not $Strict) {
            $ordered += @($candidates |
                Where-Object { -not $_.Name.StartsWith($VersionPrefix) } |
                Sort-Object -Property Name -Descending)
        }

        foreach ($dir in $ordered) {
            $kmHeader = Join-Path $dir.FullName 'km\ntddk.h'
            $sharedDir = Join-Path $dir.FullName 'shared'
            if (-not (Test-Path -LiteralPath $kmHeader)) { continue }
            if (-not (Test-Path -LiteralPath $sharedDir)) { continue }

            $libDir = Join-Path $root ("Lib\{0}\km\x64" -f $dir.Name)
            if (-not (Test-Path -LiteralPath (Join-Path $libDir 'ntoskrnl.lib'))) { continue }

            return [pscustomobject]@{
                Root    = (Resolve-Path -LiteralPath $root).Path
                Version = $dir.Name
                Lib     = (Resolve-Path -LiteralPath $libDir).Path
            }
        }
    }
    return $null
}

function Install-KitWinget {
    param([string] $PackageId)

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Warning 'winget.exe is not available; skipping the winget route'
        return $false
    }

    Write-Host "installing $PackageId through winget (several minutes)"
    & $winget.Source install --id $PackageId --exact --silent --disable-interactivity `
        --accept-source-agreements --accept-package-agreements
    $code = $LASTEXITCODE
    Write-Host "winget exited with code $code"
    return ($code -eq 0)
}

# The kit content is also published as NuGet packages: the SDK ones carry the
# shared/um headers and the user-mode libraries, Microsoft.Windows.WDK.<arch>
# carries the km headers and the kernel import libraries. Unpacking them into
# the same directory reproduces <root>\Include\<ver> and <root>\Lib\<ver>.
function Install-KitNuget {
    param(
        [string] $Destination,
        [string] $VersionPrefix,
        [string] $Architecture = 'x64'
    )

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    $packages = @(
        'microsoft.windows.sdk.cpp',
        "microsoft.windows.sdk.cpp.$Architecture",
        "microsoft.windows.wdk.$Architecture"
    )

    foreach ($id in $packages) {
        $indexUrl = "https://api.nuget.org/v3-flatcontainer/$id/index.json"
        $index = Invoke-RestMethod -Uri $indexUrl -UseBasicParsing
        $versions = @($index.versions | Where-Object { $_.StartsWith($VersionPrefix) -and -not $_.Contains('-') })
        if ($versions.Count -eq 0) {
            Write-Warning "nuget.org publishes no $VersionPrefix release of $id; skipping it"
            continue
        }
        $version = $versions[-1]
        $archive = Join-Path $Destination "$id.$version.zip"
        Write-Host "downloading $id $version (hundreds of MB in total)"
        Invoke-WebRequest -Uri "https://api.nuget.org/v3-flatcontainer/$id/$version/$id.$version.nupkg" `
            -OutFile $archive -UseBasicParsing
        Expand-Archive -LiteralPath $archive -DestinationPath $Destination -Force
        Remove-Item -LiteralPath $archive -Force
    }
}

Write-Host '::group::WDK discovery'

$kit = Find-KitContent -Roots @($env:WDK_ROOT, $KitsRoot) -VersionPrefix $PreferredVersion -Strict

if (-not $kit) {
    Write-Host "no installed WDK $PreferredVersion content found under $KitsRoot"
    $installed = Install-KitWinget -PackageId "Microsoft.WindowsWDK.$PreferredVersion"
    if ($installed) {
        $kit = Find-KitContent -Roots @($KitsRoot) -VersionPrefix $PreferredVersion -Strict
    }
}

if (-not $kit) {
    if ([string]::IsNullOrWhiteSpace($NugetRoot) -or -not (Test-Path -LiteralPath $NugetRoot)) {
        $NugetRoot = if ($env:RUNNER_TEMP) {
            Join-Path $env:RUNNER_TEMP 'wdk-nuget'
        } else {
            Join-Path ([IO.Path]::GetTempPath()) 'wdk-nuget'
        }
    }
    Install-KitNuget -Destination $NugetRoot -VersionPrefix $PreferredVersion -Architecture $Architecture
    $kit = Find-KitContent -Roots @($NugetRoot) -VersionPrefix $PreferredVersion -Strict
}

if (-not $kit) {
    # Last resort: any installed kit that still has km headers and libs.
    $kit = Find-KitContent -Roots @($env:WDK_ROOT, $KitsRoot, $NugetRoot) -VersionPrefix $PreferredVersion
    if ($kit) {
        Write-Warning "falling back to WDK $($kit.Version) instead of $PreferredVersion"
    }
}

if (-not $kit) {
    throw @"
No usable Windows Driver Kit was found.

ks-driver/build.rs needs <root>\Include\<version>\km\ntddk.h and
<root>\Lib\<version>\km\x64\ntoskrnl.lib. Install the WDK (for example
`winget install Microsoft.WindowsWDK.10.0.26100`) on the runner, or point
the job at a self-hosted runner that already has one.
"@
}

foreach ($lib in @('ntoskrnl.lib', 'hal.lib', 'BufferOverflowK.lib')) {
    if (-not (Test-Path -LiteralPath (Join-Path $kit.Lib $lib))) {
        Write-Warning "$lib is missing from $($kit.Lib); the driver link will probably fail"
    }
}

Write-Host '::endgroup::'

Write-EnvValue -Name 'WDK_ROOT' -Value $kit.Root
Write-EnvValue -Name 'WDK_LIB' -Value $kit.Lib
Write-EnvValue -Name 'WDK_VERSION' -Value $kit.Version

Add-Summary "- WDK: ``$($kit.Version)`` at ``$($kit.Root)``"
