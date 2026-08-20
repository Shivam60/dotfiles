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
    # Opt out of the automatic remote/VM terminal tweaks.
    [switch]$NoRdpTweaks,
    # Apply Windows OS tweaks (dark mode, taskbar, Explorer) from windows-tweaks.json.
    [switch]$Tweaks,
    # Limit -Tweaks to these ids, or include the opt-in ones with -AllTweaks.
    [string[]]$TweakIds,
    [switch]$AllTweaks,
    # Add the Tokyo Night gradient as a terminal background image. Off by
    # default: it tints the whole terminal navy.
    [switch]$Gradient,
    # Colour theme to apply, by file name in config\themes (e.g. tokyo-night).
    # Omitted = keep whatever was chosen last time.
    [string]$Theme,
    # Switch the colour theme and nothing else.
    [switch]$ThemeOnly,
    # Used when re-launching elevated: the child cannot write to our console.
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot

if ($LogFile) { try { Start-Transcript -Path $LogFile -Force | Out-Null } catch { } }

# When invoked via `pwsh -File`, PowerShell does NOT split "a,b" into an array,
# it binds one string containing a comma. Normalise so both forms behave.
$Groups   = @($Groups   | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Only     = @($Only     | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$TweakIds = @($TweakIds | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

function Write-Step { param([string]$m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "  [ok]   $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Write-Info { param([string]$m) Write-Host "  [..]   $m" -ForegroundColor DarkGray }

$isTty = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected

# Engines live in lib/ so bootstrap.ps1 stays readable as the orchestrator.
# Dot-sourced after the Write-* helpers because they are used inside.
. (Join-Path $repo 'lib\WindowsTweaks.ps1')

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

# Let the user tick individual tweaks. Defaults reflect the manifest's
# `default` flag, so a plain Enter applies exactly what -Tweaks would.
function Select-Tweaks {
    $all = Get-TweakList -ManifestPath (Join-Path $repo 'windows-tweaks.json')
    if (-not $all) { $script:Tweaks = $false; return }

    $items = @(); $checked = @()
    foreach ($t in $all) {
        $state = if (Test-TweakApplied -Tweak $t) { 'already set' } else { $t.Group }
        $items   += '{0,-42} {1}' -f $t.Name, $state
        $checked += $t.Default
    }

    Write-Host ''
    $checked = Read-MultiChoice -Prompt 'select tweaks' -Items $items -Checked $checked

    $ids = @()
    for ($i = 0; $i -lt $all.Count; $i++) { if ($checked[$i]) { $ids += $all[$i].Id } }
    if (-not $ids) { Write-Host 'no tweaks selected.' -ForegroundColor DarkGray; $script:Tweaks = $false; return }
    $script:TweakIds = $ids
}

function Get-Themes {
    $dir = Join-Path $repo 'config\themes'
    if (-not (Test-Path $dir)) { return @() }
    @(Get-ChildItem $dir -Filter *.json -ErrorAction SilentlyContinue | Sort-Object Name)
}

# The active theme is remembered here so a later plain -Apply keeps the look
# instead of silently reverting to whatever ships as the default.
$script:ThemeStatePath = Join-Path $HOME '.config\pwsh\theme.txt'

function Get-ActiveTheme {
    if (Test-Path $script:ThemeStatePath) {
        $n = (Get-Content $script:ThemeStatePath -Raw).Trim()
        if ($n -and (Test-Path (Join-Path $repo "config\themes\$n.json"))) { return $n }
    }
    $first = Get-Themes | Select-Object -First 1
    if ($first) { return $first.BaseName }
    return $null
}

function Select-Theme {
    # Always offer the picker, even with a single theme: the menu is how you
    # discover what is installed, and the current one is pre-selected so
    # pressing Enter is a no-op.
    $themes = Get-Themes
    if (-not $themes) { Write-Warn 'no themes found in config\themes'; return $null }
    $active = Get-ActiveTheme

    $items = @()
    foreach ($t in $themes) {
        $desc = try { (Get-Content $t.FullName -Raw | ConvertFrom-Json).description } catch { '' }
        $mark = $(if ($t.BaseName -eq $active) { '*' } else { ' ' })
        $items += '{0} {1,-16} {2}' -f $mark, $t.BaseName, $desc
    }

    $default = 1 + [array]::IndexOf(@($themes.BaseName), $active)
    if ($default -lt 1) { $default = 1 }

    Write-Host ''
    $pick = Read-Choice -Prompt 'which theme? (* = current)' -Default "$default" -Items $items
    return $themes[$pick - 1].BaseName
}

function Invoke-Menu {
    Write-Host ''
    Write-Host '  dotfiles' -ForegroundColor Cyan -NoNewline
    Write-Host " - $repo" -ForegroundColor DarkGray
    Write-Host ''

    $choice = Read-Choice -Prompt 'what do you want to do?' -Default '1' -Items @(
        'Full setup          - install packages, apply configs, apply Windows tweaks'
        'Apply configs only  - terminal, prompt, git, nvim (no installing)'
        'Change theme        - switch colours only, touch nothing else'
        'Install packages    - pick exactly which ones'
        'Windows tweaks      - dark mode, taskbar, Explorer'
        'Capture configs     - copy my local edits back into this repo'
        'Preview             - show what Apply would change, write nothing'
    )

    switch ($choice) {
        1 { $script:Install = $true; $script:Apply = $true; $script:Tweaks = $true }
        2 { $script:Apply = $true }
        3 { $script:ThemeOnly = $true }
        4 { $script:Install = $true }
        5 { $script:Tweaks = $true; Select-Tweaks; return }
        6 { $script:Capture = $true }
        7 { $script:Apply = $true; $script:Tweaks = $true; $script:WhatIfCopy = $true }
    }

    if (($script:Apply -or $script:ThemeOnly) -and -not $script:Theme) {
        $script:Theme = Select-Theme
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

if (-not ($Install -or $Apply -or $Capture -or $Tweaks -or $ThemeOnly)) {
    if ($isTty -and -not $NonInteractive) { Invoke-Menu }
    else { $Install = $true; $Apply = $true; $Tweaks = $true }
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
            # The Nerd Font family name differs by install source, so pick one
            # that actually exists here instead of trusting the stored name.
            Transform = { param($text) Convert-TerminalFont $text }
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
        [pscustomobject]@{
            Name = 'vim'
            Repo = Join-Path $repo 'config\vim\_vimrc'
            Live = Join-Path $HOME '_vimrc'
        }
        [pscustomobject]@{
            # Git for Windows bundles an MSYS vim, which is a unix build: it reads
            # ~/.vimrc and ignores ~/_vimrc entirely. Ship both so :Cheat works
            # whether `vim` is real Vim for Windows or Git's.
            Name = 'vim (git bash)'
            Repo = Join-Path $repo 'config\vim\_vimrc'
            Live = Join-Path $HOME '.vimrc'
            # Mirror of the entry above - capturing it too would race with _vimrc
            # over the same repo file.
            NoCapture = $true
        }
        [pscustomobject]@{
            # Sourced by _vimrc's :Cheat split - useless without it.
            Name = 'vim cheat sheet'
            Repo = Join-Path $repo 'config\vim\vim-cheatsheet.txt'
            Live = Join-Path $HOME 'vim-cheatsheet.txt'
        }
    )
}

function Copy-Config {
    param([string]$From, [string]$To, [string]$Label, [scriptblock]$Transform)

    if (-not (Test-Path $From)) { Write-Warn "$Label - source missing, skipped ($From)"; return }

    # Test-Path is true for a dangling symlink, so confirm it is actually readable.
    try { $new = [System.IO.File]::ReadAllText($From) }
    catch { Write-Warn "$Label - source unreadable, skipped ($From)"; return }

    # Adapt the content to this machine before comparing, so a machine-specific
    # value does not read as a difference and trigger a copy on every run.
    if ($Transform) { $new = & $Transform $new }

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

function Test-Probe {
    param([string]$Probe)
    if (-not $Probe) { return $false }
    if ($Probe -match '[\\/]') {
        return (Test-Path ([Environment]::ExpandEnvironmentVariables($Probe)))
    }
    return [bool](Get-Command $Probe -ErrorAction SilentlyContinue)
}

function Test-ConfigDependencies {
    # The configs assume their tools exist - shared.gitconfig names delta, the
    # profile names starship/zoxide/eza. Applying configs without the binaries
    # produces a machine that looks set up but breaks on first use, so say so
    # here instead of leaving it to be discovered by a failing command later.
    $pkgFile = Join-Path $repo 'packages.json'
    if (-not (Test-Path $pkgFile)) { return }
    $pkgs = Get-Content $pkgFile -Raw | ConvertFrom-Json
    $missing = @($pkgs.shell | Where-Object { $_.probe -and -not (Test-Probe $_.probe) })
    if (-not $missing) { Write-Ok 'config dependencies - all present'; return }
    foreach ($m in $missing) {
        Write-Warn "missing '$($m.probe)' - configs reference it. Install: winget install --id $($m.id)"
    }
    Write-Info 'or re-run: .\bootstrap.ps1 -Install -Groups shell'
}

function Test-RemoteDisplay {
    # Acrylic blur is composited per frame. With no real GPU that work lands on
    # the CPU and is then re-encoded for the wire, so every keystroke redraws the
    # blurred backdrop - the terminal feels laggy while TYPING, not just ugly.
    # SESSIONNAME alone is not enough: a Hyper-V/VDI box reached through an
    # enhanced session can report a console session yet still have no GPU, so
    # also treat a virtual or remote display adapter as remote.
    if ($env:SESSIONNAME -like 'RDP-*') { return $true }
    try {
        $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction Stop |
                  Select-Object -ExpandProperty Name)
        if ($gpus -and -not ($gpus | Where-Object {
                $_ -notmatch 'Remote|Hyper-V|Basic Display|VMware|VirtualBox|Citrix|Parsec|IDD' })) {
            return $true
        }
    } catch { }
    return $false
}

function Set-JsonProp {
    # ConvertFrom-Json objects throw on assignment to a property that does not
    # exist yet, so every write has to go through Add-Member when it is new.
    param($Object, [string]$Name, $Value)
    if ($Object.PSObject.Properties.Name -contains $Name) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Set-Theme {
    param([string]$Name)
    $file = Join-Path $repo "config\themes\$Name.json"
    if (-not (Test-Path $file)) {
        Write-Warn "theme '$Name' not found in config\themes"
        return
    }
    $t = Get-Content $file -Raw | ConvertFrom-Json

    if ($WhatIfCopy) { Write-Info "theme - WOULD apply '$Name' ($($t.description))"; return }

    # --- Windows Terminal: swap the scheme in and point the profiles at it ---
    $wtDir = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'
    $live  = Join-Path $wtDir 'settings.json'
    if ((Test-Path $live) -and $t.terminal) {
        $j = Get-Content $live -Raw | ConvertFrom-Json
        if ($t.terminal.scheme) {
            # Replace by name so re-applying a tweaked theme updates in place
            # rather than stacking duplicate schemes Windows Terminal would
            # silently pick between.
            $j.schemes = @(@($j.schemes | Where-Object { $_.name -ne $t.terminal.scheme.name }) + $t.terminal.scheme)
        }
        if ($t.terminal.defaults) {
            foreach ($p in $t.terminal.defaults.PSObject.Properties) {
                Set-JsonProp $j.profiles.defaults $p.Name $p.Value
            }
        }
        $j | ConvertTo-Json -Depth 32 | Set-Content $live -Encoding utf8
    }

    # --- PSReadLine: generate a snippet the profile dot-sources ---
    # Generated rather than written into the profile so switching themes never
    # has to edit (and risk mangling) the profile itself.
    if ($t.psreadline) {
        $themePs1 = Join-Path $HOME '.config\pwsh\theme.ps1'
        $dir = Split-Path $themePs1 -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $lines = @(
            "# Generated by bootstrap.ps1 -Theme $Name. Do not edit - edit"
            "# config\themes\$Name.json in the dotfiles repo and re-apply."
            'Set-PSReadLineOption -Colors @{'
        )
        foreach ($p in $t.psreadline.PSObject.Properties) {
            # Single quotes keep the raw ESC bytes literal; colour values never
            # contain a quote, so no escaping is needed.
            $lines += "    '{0}' = '{1}'" -f $p.Name, $p.Value
        }
        $lines += '}'
        Set-Content -Path $themePs1 -Value $lines -Encoding utf8
    }

    $dirState = Split-Path $script:ThemeStatePath -Parent
    if (-not (Test-Path $dirState)) { New-Item -ItemType Directory -Force -Path $dirState | Out-Null }
    Set-Content -Path $script:ThemeStatePath -Value $Name -Encoding utf8
    Write-Ok "theme - '$Name' applied ($($t.description))"
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
    Set-JsonProp $d 'useAcrylic'       $false
    Set-JsonProp $d 'antialiasingMode' 'grayscale'
    if (-not $d.opacity -or $d.opacity -eq 100) { Set-JsonProp $d 'opacity' 85 }
    # The tab row blurs independently of the profiles, so it keeps costing frames
    # even after the panes stop using acrylic.
    Set-JsonProp $j 'useAcrylicInTabRow' $false

    # A background image is drawn by Windows Terminal itself rather than by the
    # desktop compositor, so it survives a remote session where transparency is
    # dropped. It is OFF by default: the gradient is a blue navy (#1d1d30 ->
    # #222840) and tints the WHOLE terminal, which is a much bigger visual change
    # than the acrylic it replaces. Opt in with -Gradient.
    $bgSrc = Join-Path $repo 'config\windows-terminal\bg-tokyonight.png'
    $addBg = $Gradient -and (Test-Path $bgSrc)

    if ($WhatIfCopy) {
        Write-Info "rdp tweaks - WOULD drop acrylic blur, keep opacity $($d.opacity), grayscale AA"
        if ($addBg) { Write-Info 'rdp tweaks - WOULD add the gradient background image' }
        return
    }

    if ($addBg) {
        $bgDst = Join-Path $wtDir 'bg-tokyonight.png'
        # A running Windows Terminal keeps its background image open, so a plain
        # Copy-Item throws on every re-run after the first and takes the whole
        # -Apply down with it. The bytes only ever need replacing when they
        # actually differ, and in that case the terminal has to be restarted to
        # pick the new image up anyway - so warn rather than fail.
        $needsCopy = -not (Test-Path $bgDst) -or
                     (Get-FileHash $bgSrc).Hash -ne (Get-FileHash $bgDst).Hash
        if ($needsCopy) {
            try { Copy-Item $bgSrc $bgDst -Force }
            catch {
                Write-Warn 'rdp tweaks - background image in use by a running Windows Terminal; close every window and re-run to refresh it'
                $addBg = $false
            }
        }
    }
    if ($addBg) {
        # ms-appdata:///local/ resolves to this LocalState folder, so the setting
        # stays valid no matter where the repo lives.
        foreach ($kv in @{
            backgroundImage             = 'ms-appdata:///local/bg-tokyonight.png'
            backgroundImageOpacity      = 1.0
            backgroundImageStretchMode  = 'uniformToFill'
        }.GetEnumerator()) {
            Set-JsonProp $d $kv.Key $kv.Value
        }
    }
    else {
        # Strip a gradient left behind by an earlier run, otherwise dropping the
        # switch would leave the tint in place with no way to undo it.
        foreach ($k in 'backgroundImage','backgroundImageOpacity','backgroundImageStretchMode') {
            if ($d.PSObject.Properties.Name -contains $k) { $d.PSObject.Properties.Remove($k) }
        }
    }

    $j | ConvertTo-Json -Depth 32 | Set-Content $live -Encoding utf8
    Write-Ok "rdp tweaks - blur off, opacity $($d.opacity) kept, grayscale antialiasing"
    if ($addBg) { Write-Ok 'rdp tweaks - gradient background applied (survives RDP)' }
    else { Write-Info 'rdp tweaks - no background image (pass -Gradient to add the Tokyo Night gradient)' }
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
# Font face resolution
# ---------------------------------------------------------------------------
# The same Nerd Font lands under different family names depending on how it was
# installed: the winget package (DEVCOM.JetBrainsMonoNerdFont) registers the
# abbreviated "JetBrainsMono NFM", while the release zip we fall back to for
# no-admin installs registers "JetBrainsMono Nerd Font Mono". Windows Terminal
# pops "Unable to find the following fonts" whenever settings.json names one
# that is not present, so resolve it per machine instead of hardcoding.
$script:FontCandidates = @(
    'JetBrainsMono Nerd Font Mono'
    'JetBrainsMono NFM'
    'JetBrainsMono Nerd Font'
    'JetBrainsMono NF'
    'JetBrainsMonoNL NFM'
    'Cascadia Mono'      # ships with Windows, so this always resolves
    'Consolas'
)

function Get-InstalledFontFamily {
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        return (New-Object System.Drawing.Text.InstalledFontCollection).Families.Name
    } catch { return @() }
}

function Resolve-FontFace {
    $installed = Get-InstalledFontFamily
    if (-not $installed) { return $null }
    foreach ($f in $script:FontCandidates) {
        if ($installed -contains $f) { return $f }
    }
    return $null
}

# Rewrite profiles.defaults.font.face inside Windows Terminal settings *content*,
# returning the adjusted JSON. Works on text so Copy-Config can compare the
# result against the live file and skip the write when nothing changed.
function Convert-TerminalFont {
    param([string]$Text)

    try { $json = $Text | ConvertFrom-Json } catch { return $Text }
    $defaults = $json.profiles.defaults
    if (-not $defaults -or -not $defaults.font -or -not $defaults.font.face) { return $Text }

    $wanted = $defaults.font.face
    $installed = Get-InstalledFontFamily
    if (-not $installed -or $installed -contains $wanted) { return $Text }

    $face = Resolve-FontFace
    if (-not $face) {
        Write-Warn "font - '$wanted' is not installed and no fallback was found; run -Only DEVCOM.JetBrainsMonoNerdFont"
        return $Text
    }

    Write-Info "font - '$wanted' not installed here, using '$face'"
    $defaults.font.face = $face
    return ($json | ConvertTo-Json -Depth 32)
}

# ---------------------------------------------------------------------------
# Apply / Capture
# ---------------------------------------------------------------------------
if ($Apply) {
    Write-Step 'Applying configs to this machine'
    foreach ($c in Get-ConfigMap) {
        if ($c.Skip) { Write-Info "$($c.Name) - not installed here, skipped"; continue }
        Copy-Config -From $c.Repo -To $c.Live -Label $c.Name -Transform $c.Transform
    }
    Set-GitInclude
    # After the config copy (which would otherwise overwrite the scheme) and
    # before the RDP tweaks, which only fill in what the theme left unset.
    $themeName = if ($Theme) { $Theme } else { Get-ActiveTheme }
    if ($themeName) { Set-Theme -Name $themeName }
    # Auto-apply on remote/GPU-less machines: leaving this to a flag meant the
    # laggy default silently shipped to every VM until someone noticed.
    if ($NoRdpTweaks) { Write-Info 'remote terminal tweaks skipped (-NoRdpTweaks)' }
    elseif ($RdpTweaks -or (Test-RemoteDisplay)) { Set-RdpTweaks }
    Test-ConfigDependencies
    Write-Host "`nOpen a NEW terminal tab to pick up the changes." -ForegroundColor Cyan
}

if ($ThemeOnly) {
    Write-Step 'Changing theme'
    $themeName = if ($Theme) { $Theme } else { Get-ActiveTheme }
    if ($themeName) { Set-Theme -Name $themeName } else { Write-Warn 'no theme to apply' }
    Write-Host "`nOpen a NEW terminal tab to pick up the changes." -ForegroundColor Cyan
}

if ($Capture) {
    Write-Step 'Capturing configs from this machine into the repo'
    if (Test-RemoteDisplay) {
        Write-Warn 'remote session: the terminal tweaks applied here are machine-local, do not commit them'
    }
    foreach ($c in Get-ConfigMap) {
        if ($c.Skip) { Write-Info "$($c.Name) - not installed here, skipped"; continue }
        if ($c.NoCapture) { continue }
        Copy-Config -From $c.Live -To $c.Repo -Label $c.Name
    }
    # The live file names whatever font this machine resolved to. Put the canonical
    # name back so machines with different Nerd Font builds don't fight over it.
    $__wtRepo = (Get-ConfigMap | Where-Object { $_.Name -eq 'Windows Terminal' }).Repo
    if ($__wtRepo -and (Test-Path $__wtRepo)) {
        try {
            $__j = Get-Content $__wtRepo -Raw | ConvertFrom-Json
            if ($__j.profiles.defaults.font.face -and
                $__j.profiles.defaults.font.face -ne $script:FontCandidates[0]) {
                $__j.profiles.defaults.font.face = $script:FontCandidates[0]
                $__j | ConvertTo-Json -Depth 32 | Set-Content $__wtRepo -Encoding UTF8
                Write-Info "font - normalised repo copy to '$($script:FontCandidates[0])'"
            }
        } catch { Write-Warn 'font - could not normalise repo copy' }
    }
    Write-Host "`nReview with 'git diff', then commit and push." -ForegroundColor Cyan
}

if ($Tweaks) {
    Write-Step 'Applying Windows tweaks'
    Invoke-WindowsTweaks -ManifestPath (Join-Path $repo 'windows-tweaks.json') `
                         -Only $TweakIds -All:$AllTweaks -Preview:$WhatIfCopy
}

if ($LogFile) { try { Stop-Transcript | Out-Null } catch { } }
