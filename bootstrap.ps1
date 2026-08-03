<#
.SYNOPSIS
    Bootstrap a Windows machine with this dotfiles configuration.

.DESCRIPTION
    Three independent phases, so you can re-run any part safely:

      -Install   Install packages from packages.json (winget) + PowerShell modules.
      -Apply     Copy configs from this repo onto the machine.
      -Capture   Copy configs from the machine back into this repo (then git commit).

    With no switches, runs -Install then -Apply (a full new-machine setup).

    Configs are COPIED, not symlinked. Windows Terminal silently ignores a
    symlinked settings.json and falls back to its built-in defaults, which makes
    symlink-based sync fail with no error at all. Copying is boring and works.

.EXAMPLE
    .\bootstrap.ps1                 # new machine: install everything, apply configs
.EXAMPLE
    .\bootstrap.ps1 -Apply          # after `git pull`, push configs onto this machine
.EXAMPLE
    .\bootstrap.ps1 -Capture        # after editing configs locally, pull them into the repo
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Apply,
    [switch]$Capture,
    [switch]$IncludeApps,
    [switch]$WhatIfCopy
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot

if (-not ($Install -or $Apply -or $Capture)) { $Install = $true; $Apply = $true }

function Write-Step { param([string]$m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "  [ok]   $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Write-Info { param([string]$m) Write-Host "  [..]   $m" -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# Machine paths. Resolved at runtime: $PROFILE and the OneDrive-redirected
# Documents folder differ per machine, so these must never be hardcoded.
# ---------------------------------------------------------------------------
function Get-ConfigMap {
    $wtDir     = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'
    $wingetDir = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState'

    @(
        [pscustomobject]@{
            Name = 'PowerShell profile'
            Repo = Join-Path $repo 'config\powershell\Microsoft.PowerShell_profile.ps1'
            Live = $PROFILE.CurrentUserCurrentHost
        }
        [pscustomobject]@{
            Name = 'starship'
            Repo = Join-Path $repo 'config\starship\starship.toml'
            Live = Join-Path $HOME '.config\starship.toml'
        }
        [pscustomobject]@{
            Name = 'Windows Terminal'
            Repo = Join-Path $repo 'config\windows-terminal\settings.json'
            Live = Join-Path $wtDir 'settings.json'
            # Only if Windows Terminal is actually installed on this machine.
            Skip = -not (Test-Path $wtDir)
        }
        [pscustomobject]@{
            Name = 'winget'
            Repo = Join-Path $repo 'config\winget\settings.json'
            Live = Join-Path $wingetDir 'settings.json'
            Skip = -not (Test-Path $wingetDir)
        }
        [pscustomobject]@{
            Name = 'neovim'
            Repo = Join-Path $repo 'config\nvim\init.lua'
            Live = Join-Path $env:LOCALAPPDATA 'nvim\init.lua'
        }
    )
}

function Copy-Config {
    param([string]$From, [string]$To, [string]$Label)

    if (-not (Test-Path $From)) { Write-Warn "$Label - source missing, skipped ($From)"; return }

    # Test-Path is true for a dangling symlink, so confirm it is actually readable.
    try { $new = [System.IO.File]::ReadAllText($From) }
    catch { Write-Warn "$Label - source unreadable, skipped ($From)"; return }

    $dir = Split-Path $To -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    # A symlink here would make us write through to the old link target instead
    # of the real location, so replace it with a regular file.
    if (Test-Path $To) {
        $item = Get-Item $To -Force
        if ($item.LinkType) {
            Write-Warn "$Label - replacing $($item.LinkType) -> $($item.Target)"
            if (-not $WhatIfCopy) { $item.Delete() }
        }
    }

    $current = $null
    if (Test-Path $To) {
        try { $current = [System.IO.File]::ReadAllText($To) } catch { $current = $null }
    }

    if ($null -ne $current -and $current -eq $new) {
        Write-Info "$Label - already up to date"
        return
    }

    if ($WhatIfCopy) { Write-Info "$Label - WOULD copy -> $To"; return }

    if ($null -ne $current) {
        $bak = "$To.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Copy-Item $To $bak -Force
        Write-Info "$Label - backed up to $(Split-Path $bak -Leaf)"
    }
    [System.IO.File]::WriteAllText($To, $new)
    Write-Ok "$Label -> $To"
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
if ($Install) {
    Write-Step 'Installing packages'

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget not found. Install 'App Installer' from the Microsoft Store, then re-run."
    }

    $pkgFile = Join-Path $repo 'packages.json'
    $pkgs = Get-Content $pkgFile -Raw | ConvertFrom-Json

    $groups = @('fonts','shell','dev')
    if ($IncludeApps) { $groups += 'apps' } else { Write-Info "skipping 'apps' group (pass -IncludeApps to include)" }

    $installed = (winget list --disable-interactivity 2>$null) -join "`n"

    foreach ($g in $groups) {
        Write-Host "  -- $g --" -ForegroundColor DarkCyan
        foreach ($p in $pkgs.$g) {
            if ($installed -match [regex]::Escape($p.id)) { Write-Info "$($p.id) already installed"; continue }
            $args = @('install','--id',$p.id,'-e','--accept-source-agreements','--accept-package-agreements','--disable-interactivity')
            if ($p.extraArgs) { $args += $p.extraArgs }
            Write-Info "installing $($p.id)"
            & winget @args 2>&1 | Select-Object -Last 1 | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
        }
    }

    Write-Host "  -- PowerShell modules --" -ForegroundColor DarkCyan
    foreach ($m in $pkgs.psModules) {
        $have = Get-Module -ListAvailable $m.name | Sort-Object Version -Descending | Select-Object -First 1
        $needs = (-not $have) -or ($m.minimumVersion -and $have.Version -lt [version]$m.minimumVersion)
        if ($needs) {
            Write-Info "installing module $($m.name)"
            Install-Module $m.name -Scope CurrentUser -Force -AllowClobber -SkipPublisherCheck
            Write-Ok "$($m.name)"
        } else { Write-Info "$($m.name) $($have.Version) ok" }
    }

    # starship lives in Program Files and is not added to PATH by its installer
    $ss = Join-Path $env:ProgramFiles 'starship\bin'
    if ((Test-Path $ss)) {
        $userPath = [Environment]::GetEnvironmentVariable('PATH','User')
        if ($userPath -notlike "*$ss*") {
            [Environment]::SetEnvironmentVariable('PATH', "$userPath;$ss", 'User')
            Write-Ok "added starship to User PATH"
        }
    }
}

# ---------------------------------------------------------------------------
# Apply / Capture
# ---------------------------------------------------------------------------
if ($Apply) {
    Write-Step 'Applying configs to this machine'
    foreach ($c in Get-ConfigMap) {
        if ($c.Skip) { Write-Info "$($c.Name) - not installed here, skipped"; continue }
        Copy-Config -From $c.Repo -To $c.Live -Label $c.Name
    }
    Write-Host "`nOpen a NEW terminal tab to pick up the changes." -ForegroundColor Cyan
}

if ($Capture) {
    Write-Step 'Capturing configs from this machine into the repo'
    foreach ($c in Get-ConfigMap) {
        if ($c.Skip) { Write-Info "$($c.Name) - not installed here, skipped"; continue }
        Copy-Config -From $c.Live -To $c.Repo -Label $c.Name
    }
    Write-Host "`nReview with 'git diff', then commit and push." -ForegroundColor Cyan
}
