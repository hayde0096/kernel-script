<#
.SYNOPSIS
    Makes the private `dt-loader` mapper crate available at the sibling path
    the workspace expects (`..\driver-toolkit\dt-loader`).

.DESCRIPTION
    The workspace declares `dt-loader = { path = "../driver-toolkit/dt-loader" }`
    and the sources live in the private repository
    https://github.com/lipeilin2006/driver-loader. Cargo resolves every path
    dependency of the workspace graph, so *any* cargo command — even
    `cargo build -p ks-driver` — fails when that directory is missing.

    CI therefore has two modes:

      * DT_LOADER_TOKEN set  -> clone the private repository (read-only PAT)
      * token absent         -> write a placeholder crate so cargo can still
                                resolve the graph; the two user-mode binaries
                                that actually link the mapper are skipped
                                (they import dt_loader items, so they cannot
                                compile against the placeholder).

    Outputs: `mapped` = true when the real crate was checked out.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$workspace = $env:GITHUB_WORKSPACE
if ([string]::IsNullOrWhiteSpace($workspace)) {
    $workspace = (Get-Location).Path
}

$destination = Join-Path (Split-Path -Parent $workspace) 'driver-toolkit\dt-loader'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null

function Set-StepOutput {
    param([string] $Name, [string] $Value)

    if ($env:GITHUB_OUTPUT) {
        [IO.File]::AppendAllText($env:GITHUB_OUTPUT, "$Name=$Value`n")
    }
    Write-Host "$Name=$Value"
}

function New-PlaceholderCrate {
    param([string] $Path)

    New-Item -ItemType Directory -Force -Path (Join-Path $Path 'src') | Out-Null
    $manifest = @'
# Placeholder created by .github/scripts/setup-dt-loader.ps1.
# The real mapper lives in the private repository lipeilin2006/driver-loader;
# this stub exists only so cargo can resolve the workspace path dependency.
[package]
name = "dt-loader"
version = "0.1.0"
edition = "2021"

[lib]
path = "src/lib.rs"
'@
    [IO.File]::WriteAllText((Join-Path $Path 'Cargo.toml'), $manifest)
    $lib = @'
//! Placeholder for the private `dt-loader` mapper crate.
//!
//! Nothing is compiled against this stub: without the private repository the
//! job only builds `ks-driver.sys`, and the crates that link the mapper
//! (`ks-sdk`, `ks-gui`, `ks-test`) are skipped.
'@
    [IO.File]::WriteAllText((Join-Path $Path 'src\lib.rs'), $lib)
}

if (Test-Path -LiteralPath $destination) {
    Remove-Item -LiteralPath $destination -Recurse -Force
}

$token = $env:DT_LOADER_TOKEN
$repository = $env:DT_LOADER_REPO
if ([string]::IsNullOrWhiteSpace($repository)) {
    $repository = 'lipeilin2006/driver-loader'
}

if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Warning "DT_LOADER_TOKEN is not set: placing a placeholder crate at $destination"
    Write-Warning 'Only ks-driver.sys will be built; ks-gui.exe / ks-test.exe need the real mapper.'
    New-PlaceholderCrate -Path $destination
    Set-StepOutput -Name 'mapped' -Value 'false'
    if ($env:GITHUB_STEP_SUMMARY) {
        [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY,
            "- dt-loader: **placeholder** (secret ``DT_LOADER_TOKEN`` missing) - only ``ks-driver.sys`` built`n")
    }
    exit 0
}

# Basic auth with an x-access-token password works for fine-grained PATs and
# for the GITHUB_TOKEN of the private repository. The base64 blob is masked so
# it cannot leak through a failing git invocation.
$credentials = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$token"))
Write-Host "::add-mask::$credentials"

# A rejected token must fail immediately instead of waiting on a credential
# prompt that CI can never answer.
$env:GIT_TERMINAL_PROMPT = '0'

$gitArguments = @(
    '-c', 'credential.helper=',
    '-c', "http.extraHeader=AUTHORIZATION: basic $credentials",
    'clone', '--depth', '1', '--no-tags'
)
if (-not [string]::IsNullOrWhiteSpace($env:DT_LOADER_REF)) {
    $gitArguments += @('--branch', $env:DT_LOADER_REF)
}
$gitArguments += @("https://github.com/$repository.git", $destination)

Write-Host "cloning $repository into $destination"
& git @gitArguments
if ($LASTEXITCODE -ne 0) {
    throw "git clone of $repository failed (exit $LASTEXITCODE); check DT_LOADER_TOKEN and DT_LOADER_REPO"
}

$manifest = Join-Path $destination 'Cargo.toml'
if (-not (Test-Path -LiteralPath $manifest)) {
    throw "$destination does not look like the dt-loader crate (no Cargo.toml)"
}

Write-Host '::group::dt-loader checkout'
Write-Host (Get-Content -LiteralPath $manifest -TotalCount 12 | Out-String)
Write-Host '::endgroup::'

$refLabel = if ([string]::IsNullOrWhiteSpace($env:DT_LOADER_REF)) { 'default branch' } else { $env:DT_LOADER_REF }

Set-StepOutput -Name 'mapped' -Value 'true'
if ($env:GITHUB_STEP_SUMMARY) {
    [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY,
        "- dt-loader: ``$repository`` at ``$refLabel```n")
}
