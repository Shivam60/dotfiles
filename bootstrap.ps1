<#
.SYNOPSIS
    Bootstrap a Windows machine with this dotfiles configuration.

.DESCRIPTION
    Three independent phases, so you can re-run any part safely:

      -Install   Install packages from packages.json (winget) + PowerShell modules.
      -Apply     Copy configs from this repo onto the machine.
      -Capture   Copy configs from the machine back into this repo (then git commit).

    With no switches, runs -Install then -Apply (a full new-machine setup).

      -Install elevates itself ONCE up front so winget does not raise a separate UAC
      prompt for every package. Pass -NoElevate to skip that.

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
    [switch]$NoElevate,
    [switch]$WhatIfCopy,
    # Limit -Install to these groups from packages.json. Empty = fonts+shell+dev.
    [string[]]$Groups,
    # Limit -Install to these winget IDs.
    [string[]]$Only,
    # Force the interactive menu, or force it off for scripted runs.
    [switch]$Menu,
    [switch]$NonInteractive,
    # Adjust the applied Windows Terminal settings for a remote session.
    [switch]$RdpTweaks,
    # Used when re-launching elevated: the child cannot write to our console.
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot

if ($LogFile) { try { Start-Transcript -Path $LogFile -Force | Out-Null } catch { } }

# When invoked via `pwsh -File`, PowerShell does NOT split "a,b" into an array,
# it binds one string containing a comma. Normalise so both forms behave.
$Groups = @($Groups | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Only   = @($Only   | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

function Write-Step { param([string]$m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "  [ok]   $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Write-Info { param([string]$m) Write-Host "  [..]   $m" -ForegroundColor DarkGray }

$isTty = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------
function Read-Choice {
    param([string]$Prompt, [string[]]$Items, [string]$Default = '')

    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ('  [{0}] ' -f ($i + 1)) -ForegroundColor Cyan -NoNewline
        Write-Host $Items[$i]
    }
    Write-Host '  [q] ' -ForegroundColor DarkGray -NoNewline; Write-Host 'quit'
    while ($true) {
        $hint = if ($Default) { " [$Default]" } else { '' }
        $ans = (Read-Host "$Prompt$hint").Trim()
        if (-not $ans -and $Default) { $ans = $Default }
        if ($ans -eq 'q') { Write-Host 'nothing to do.' -ForegroundColor DarkGray; exit 0 }
        $n = 0
        if ([int]::TryParse($ans, [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) { return $n }
        Write-Host "  pick 1-$($Items.Count), or q" -ForegroundColor Yellow
    }
}

function Read-MultiChoice {
    param([string]$Prompt, [string[]]$Items, [bool[]]$Checked)

    while ($true) {
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $mark = if ($Checked[$i]) { 'x' } else { ' ' }
            $col  = if ($Checked[$i]) { 'Green' } else { 'DarkGray' }
            Write-Host ('  {0,2}. [{1}] ' -f ($i + 1), $mark) -ForegroundColor $col -NoNewline
            Write-Host $Items[$i]
        }
        Write-Host '  numbers toggle (e.g. "1,3-5"), a = all, n = none, ' -ForegroundColor DarkGray -NoNewline
        Write-Host 'Enter = accept' -ForegroundColor Cyan
        $ans = (Read-Host $Prompt).Trim()

        if (-not $ans) { return $Checked }
        if ($ans -eq 'q') { exit 0 }
        if ($ans -eq 'a') { for ($i = 0; $i -lt $Checked.Count; $i++) { $Checked[$i] = $true };  continue }
        if ($ans -eq 'n') { for ($i = 0; $i -lt $Checked.Count; $i++) { $Checked[$i] = $false }; continue }

        foreach ($tok in ($ans -split '[,\s]+' | Where-Object { $_ })) {
            if ($tok -match '^(\d+)-(\d+)$') {
                foreach ($k in [int]$Matches[1]..[int]$Matches[2]) {
                    if ($k -ge 1 -and $k -le $Checked.Count) { $Checked[$k-1] = -not $Checked[$k-1] }
                }
            } elseif ($tok -match '^\d+$') {
                $k = [int]$tok
                if ($k -ge 1 -and $k -le $Checked.Count) { $Checked[$k-1] = -not $Checked[$k-1] }
                else { Write-Host "  ignoring '$tok'" -ForegroundColor Yellow }
            } else { Write-Host "  ignoring '$tok'" -ForegroundColor Yellow }
        }
        Write-Host ''
    }
}

function Invoke-Menu {
    Write-Host ''
    Write-Host '  dotfiles' -ForegroundColor Cyan -NoNewline
    Write-Host " - $repo" -ForegroundColor DarkGray
    Write-Host ''

    $choice = Read-Choice -Prompt 'what do you want to do?' -Default '1' -Items @(
        'Full setup          - install packages, then apply configs'
        'Apply configs only  - terminal, prompt, git, nvim (no installing)'
        'Install packages    - pick exactly which ones'
        'Capture configs     - copy my local edits back into this repo'
        'Preview             - show what Apply would change, write nothing'
    )

    switch ($choice) {
        1 { $script:Install = $true; $script:Apply = $true }
        2 { $script:Apply = $true }
        3 { $script:Install = $true }
        4 { $script:Capture = $true }
        5 { $script:Apply = $true; $script:WhatIfCopy = $true }
    }

    if (-not $script:Install) { return }

    # Which packages?
    $pkgs = Get-Content (Join-Path $repo 'packages.json') -Raw | ConvertFrom-Json
    $allGroups = @('fonts','shell','dev','apps')

    Write-Host ''
    $scope = Read-Choice -Prompt 'which packages?' -Default '1' -Items @(
        'Essentials    - fonts, shell tools, dev tools (skips browsers etc.)'
        'Everything    - also PowerToys, Chrome, Obsidian, ...'
        'Let me pick individually'
    )

    if ($scope -eq 1) { $script:Groups = @('fonts','shell','dev'); return }
    if ($scope -eq 2) { $script:Groups = $allGroups; $script:IncludeApps = $true; return }

    $items = @(); $checked = @()
    foreach ($g in $allGroups) {
        foreach ($p in $pkgs.$g) {
            $label = '{0,-30} {1}' -f $p.id, ($(if ($p.note) { $p.note } else { $g }))
            $items += $label
            # default: essentials on, apps off
            $checked += ($g -ne 'apps')
        }
    }
    Write-Host ''
    $checked = Read-MultiChoice -Prompt 'select packages' -Items $items -Checked $checked

    $ids = @()
    $flat = foreach ($g in $allGroups) { foreach ($p in $pkgs.$g) { $p.id } }
    for ($i = 0; $i -lt $flat.Count; $i++) { if ($checked[$i]) { $ids += $flat[$i] } }

    if (-not $ids) { Write-Host 'no packages selected.' -ForegroundColor DarkGray; $script:Install = $false; return }
    $script:Only   = $ids
    $script:Groups = $allGroups
}

if (-not ($Install -or $Apply -or $Capture)) {
    if ($isTty -and -not $NonInteractive) { Invoke-Menu }
    else { $Install = $true; $Apply = $true }
} elseif ($Menu) { Invoke-Menu }

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

function Set-GitInclude {
    # ~/.gitconfig is NOT copied: it holds corp identity, credential endpoints
    # and tenant IDs that must never reach GitHub. Instead the machine's config
    # includes the portable half from this repo. Local values still win, because
    # the include sits above them.
    $shared = (Join-Path $repo 'config\git\shared.gitconfig') -replace '\\','/'
    if (-not (Test-Path $shared)) { Write-Warn 'git - shared.gitconfig missing, skipped'; return }

    $gitconfig = Join-Path $HOME '.gitconfig'
    $existing = @(git config --global --get-all include.path 2>$null)
    if ($existing -contains $shared) { Write-Info 'git - include already set'; return }

    if ($WhatIfCopy) { Write-Info "git - WOULD add include.path -> $shared"; return }

    if (Test-Path $gitconfig) {
        Copy-Item $gitconfig "$gitconfig.bak-$(Get-Date -Format yyyyMMdd-HHmmss)" -Force
    }
    # Prepend, so anything already in ~/.gitconfig overrides the shared defaults.
    $head = "[include]`n`tpath = $shared`n"
    $body = if (Test-Path $gitconfig) { [System.IO.File]::ReadAllText($gitconfig) } else { '' }
    [System.IO.File]::WriteAllText($gitconfig, $head + $body)
    Write-Ok "git - include.path -> $shared"
}

function Install-FontPerUser {
    # Dev boxes often refuse admin, and winget's font package needs it. Fonts can
    # be installed for the current user with no elevation at all: drop the files
    # in the per-user font folder and register them under HKCU.
    param([string]$Url, [string]$Filter, [string]$Label)

    $userFonts = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    $regKey    = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    New-Item -ItemType Directory -Force -Path $userFonts | Out-Null
    if (-not (Test-Path $regKey)) { New-Item -Path $regKey -Force | Out-Null }

    $tmp = Join-Path $env:TEMP "font-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $zip = Join-Path $tmp 'font.zip'
        Write-Info "$Label - downloading (no admin needed)"
        $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest -Uri $Url -OutFile $zip -UseBasicParsing } finally { $ProgressPreference = $old }

        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        $ttfs = Get-ChildItem $tmp -Recurse -Include *.ttf, *.otf |
                Where-Object { -not $Filter -or $_.Name -like "$Filter*" }
        if (-not $ttfs) { Write-Warn "$Label - archive had no fonts matching '$Filter'"; return $false }

        $n = 0
        foreach ($f in $ttfs) {
            $dest = Join-Path $userFonts $f.Name
            Copy-Item $f.FullName $dest -Force
            # The registry value name is what apps see; the suffix matters for TTF.
            $title = [IO.Path]::GetFileNameWithoutExtension($f.Name)
            $suffix = if ($f.Extension -eq '.otf') { ' (OpenType)' } else { ' (TrueType)' }
            New-ItemProperty -Path $regKey -Name "$title$suffix" -Value $dest -PropertyType String -Force | Out-Null
            $n++
        }
        Write-Ok "$Label - installed $n font file(s) for current user"
        return $true
    }
    catch { Write-Warn "$Label - per-user font install failed: $($_.Exception.Message)"; return $false }
    finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

function Set-RdpTweaks {
    # Acrylic is the frosted-blur effect and needs local hardware composition, so
    # it never renders in a remote session. Plain opacity is just an alpha value
    # on the window and DOES work over RDP on Windows 11, so keep the see-through
    # look and only drop the blur. ClearType subpixel AA also fringes badly under
    # RDP compression, so switch to grayscale.
    # The repo copy stays canonical - only the LIVE file is patched.
    $wtDir = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'
    $live  = Join-Path $wtDir 'settings.json'
    if (-not (Test-Path $live)) { Write-Warn 'rdp tweaks - Windows Terminal settings not found'; return }

    $j = Get-Content $live -Raw | ConvertFrom-Json
    $d = $j.profiles.defaults
    $d.useAcrylic       = $false
    $d.antialiasingMode = 'grayscale'
    if (-not $d.opacity -or $d.opacity -eq 100) { $d.opacity = 85 }

    # If the RDP client will not pass alpha through, transparency is simply gone.
    # A background image is drawn by Windows Terminal itself rather than by the
    # desktop compositor, so it always survives the remote session and restores
    # some of the depth that the blur used to provide.
    $bgSrc = Join-Path $repo 'config\windows-terminal\bg-tokyonight.png'
    $addBg = Test-Path $bgSrc

    if ($WhatIfCopy) {
        Write-Info "rdp tweaks - WOULD drop acrylic blur, keep opacity $($d.opacity), grayscale AA"
        if ($addBg) { Write-Info 'rdp tweaks - WOULD add the gradient background image' }
        return
    }

    if ($addBg) {
        Copy-Item $bgSrc (Join-Path $wtDir 'bg-tokyonight.png') -Force
        # ms-appdata:///local/ resolves to this LocalState folder, so the setting
        # stays valid no matter where the repo lives.
        $props = $d.PSObject.Properties.Name
        foreach ($kv in @{
            backgroundImage             = 'ms-appdata:///local/bg-tokyonight.png'
            backgroundImageOpacity      = 1.0
            backgroundImageStretchMode  = 'uniformToFill'
        }.GetEnumerator()) {
            if ($props -contains $kv.Key) { $d.($kv.Key) = $kv.Value }
            else { $d | Add-Member -NotePropertyName $kv.Key -NotePropertyValue $kv.Value }
        }
    }

    $j | ConvertTo-Json -Depth 32 | Set-Content $live -Encoding utf8
    Write-Ok "rdp tweaks - blur off, opacity $($d.opacity) kept, grayscale antialiasing"
    if ($addBg) { Write-Ok 'rdp tweaks - gradient background applied (survives RDP)' }
    Write-Info 'transparency may still be dropped by the RDP client; the gradient is the fallback'
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

    $groups = if ($Groups) { $Groups } else { @('fonts','shell','dev') }
    if ($IncludeApps -and $groups -notcontains 'apps') { $groups += 'apps' }
    if (-not $Groups -and -not $IncludeApps) { Write-Info "skipping 'apps' group (pass -IncludeApps to include)" }
    if ($Only) { Write-Info "limited to: $($Only -join ', ')" }

    # -- installed-package detection -------------------------------------------
    # 'winget list' is slow (~5s), so it is fetched at most once and only if a
    # cheap probe has not already answered the question.
    $script:wgExact = $null
    $script:wgPrefix = $null
    function Get-WingetIds {
        if ($null -ne $script:wgExact) { return }
        Write-Info 'querying installed packages (one-time, ~5s)'
        $script:wgExact  = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $script:wgPrefix = New-Object System.Collections.Generic.List[string]
        foreach ($line in (winget list --disable-interactivity 2>$null)) {
            # IDs never contain spaces, so tokenising gives exact matches and
            # avoids 'Microsoft.Edge' falsely matching 'Microsoft.Edge.Canary'.
            foreach ($tok in ($line -split '\s{2,}|\s' | Where-Object { $_ })) {
                if ($tok.EndsWith([char]0x2026)) {
                    # Narrow consoles truncate the Id column with an ellipsis.
                    $script:wgPrefix.Add($tok.TrimEnd([char]0x2026))
                } else {
                    [void]$script:wgExact.Add($tok)
                }
            }
        }
    }
    function Test-WingetId {
        param([string]$Id)
        Get-WingetIds
        if ($script:wgExact.Contains($Id)) { return $true }
        foreach ($pre in $script:wgPrefix) {
            if ($pre.Length -ge 4 -and $Id.StartsWith($pre, 'OrdinalIgnoreCase')) { return $true }
        }
        return $false
    }
    function Test-Probe {
        param([string]$Probe)
        if (-not $Probe) { return $false }
        if ($Probe -match '[\\/]') {
            return (Test-Path ([Environment]::ExpandEnvironmentVariables($Probe)))
        }
        return [bool](Get-Command $Probe -ErrorAction SilentlyContinue)
    }
    function Test-FontInstalled {
        param([string]$Match)
        foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts',
                       'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts') {
            $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
            if ($p -and ($p.PSObject.Properties.Name -match [regex]::Escape($Match))) { return $true }
        }
        return $false
    }
    function Get-InstalledReason {
        param($p)
        if ($p.font -and (Test-FontInstalled $p.font))  { return 'font present' }
        if (Test-Probe $p.probe)                        { return "found '$($p.probe)'" }
        if (Test-WingetId $p.id)                        { return 'winget' }
        foreach ($alt in @($p.altIds)) {
            if ($alt -and (Test-WingetId $alt))         { return "$alt installed instead" }
        }
        return $null
    }

    # Work out what is actually missing BEFORE elevating, so a machine that is
    # already set up never triggers a UAC prompt at all.
    $pending = @()
    foreach ($g in $groups) {
        $list = @($pkgs.$g | Where-Object { -not $Only -or $Only -contains $_.id })
        if (-not $list) { continue }
        Write-Host "  -- $g --" -ForegroundColor DarkCyan
        foreach ($p in $list) {
            $why = Get-InstalledReason $p
            if ($why) { Write-Info "$($p.id) - already installed ($why)" }
            else      { Write-Warn "$($p.id) - MISSING"; $pending += $p }
        }
    }

    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    # Fonts can be installed per-user without elevation, so handle them before
    # deciding whether to prompt for admin at all. On a locked-down dev box this
    # is often the difference between a working prompt and a screen of boxes.
    if (-not $isAdmin) {
        $stillPending = @()
        foreach ($p in $pending) {
            if ($p.fontUrl -and (Install-FontPerUser -Url $p.fontUrl -Filter $p.fontFilter -Label $p.id)) { continue }
            $stillPending += $p
        }
        $pending = $stillPending
    }

    if (-not $pending) {
        Write-Ok 'all packages already installed - nothing to do'
    }
    elseif (-not $isAdmin -and -not $NoElevate) {
        # One UAC prompt for the whole batch instead of one per package.
        Write-Step "Elevating once to install $($pending.Count) package(s)"
        Write-Info ($pending.id -join ', ')
        $log = Join-Path $env:TEMP "dotfiles-install-$(Get-Date -Format yyyyMMdd-HHmmss).log"
        $childArgs = @('-NoProfile','-File',$PSCommandPath,'-Install','-NoElevate','-NonInteractive')
        # Pass the resolved selection through, so the elevated run installs
        # exactly this set and never re-prompts.
        $childArgs += '-Groups'; $childArgs += ($groups -join ',')
        $childArgs += '-Only';   $childArgs += (($pending.id) -join ',')
        $childArgs += '-LogFile'; $childArgs += $log
        if ($IncludeApps) { $childArgs += '-IncludeApps' }
        $proc = Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs `
                              -ArgumentList $childArgs -PassThru -Wait
        if ($proc.ExitCode -ne 0) { Write-Warn "elevated installer exited with $($proc.ExitCode)" }
        else { Write-Ok 'elevated install finished' }
        if (Test-Path $log) {
            Get-Content $log | Where-Object { $_ -match '^\s*\[(ok|warn|\.\.)\]|^\s{9}\S' } |
                Select-Object -Last 20 | ForEach-Object { Write-Host "  | $_" -ForegroundColor DarkGray }
            Write-Info "full log: $log"
        }
    }
    else {
        foreach ($p in $pending) {
            $wgArgs = @('install','--id',$p.id,'-e','--accept-source-agreements',
                        '--accept-package-agreements','--disable-interactivity')
            if ($p.extraArgs) { $wgArgs += $p.extraArgs }
            Write-Info "installing $($p.id)"
            & winget @wgArgs 2>&1 | Select-Object -Last 1 |
                ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
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
    Set-GitInclude
    if ($RdpTweaks) { Set-RdpTweaks }
    elseif ($env:SESSIONNAME -like 'RDP-*') {
        Write-Info 'remote session detected - re-run with -RdpTweaks if acrylic looks flat'
    }
    Write-Host "`nOpen a NEW terminal tab to pick up the changes." -ForegroundColor Cyan
}

if ($Capture) {
    Write-Step 'Capturing configs from this machine into the repo'
    if ($env:SESSIONNAME -like 'RDP-*') {
        Write-Warn 'remote session: if you ran -RdpTweaks here, do not commit the Windows Terminal change'
    }
    foreach ($c in Get-ConfigMap) {
        if ($c.Skip) { Write-Info "$($c.Name) - not installed here, skipped"; continue }
        Copy-Config -From $c.Live -To $c.Repo -Label $c.Name
    }
    Write-Host "`nReview with 'git diff', then commit and push." -ForegroundColor Cyan
}

if ($LogFile) { try { Stop-Transcript | Out-Null } catch { } }
