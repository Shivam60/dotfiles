<#
.SYNOPSIS
    Applies declarative Windows tweaks from windows-tweaks.json.

.DESCRIPTION
    Dot-sourced by bootstrap.ps1. Keeping the engine here means adding a new
    customization is a data change in windows-tweaks.json, not a code change.

    Everything is idempotent: a tweak already in the desired state is reported
    and skipped, and Explorer is only restarted when something actually changed.

    All tweaks are HKCU (per-user), so none of this needs administrator rights.
#>

# Broadcast WM_SETTINGCHANGE so running apps pick up theme changes without a
# sign-out. Without this, dark mode only applies to newly launched processes.
function Publish-SettingChange {
    if (-not ('WinApi.NativeMethods' -as [type])) {
        Add-Type -Namespace WinApi -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }
    $HWND_BROADCAST   = [IntPtr]0xffff
    $WM_SETTINGCHANGE = 0x001A
    $SMTO_ABORTIFHUNG = 0x0002
    $res = [UIntPtr]::Zero
    foreach ($topic in 'ImmersiveColorSet', 'WindowsThemeElement') {
        [void][WinApi.NativeMethods]::SendMessageTimeout(
            $HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero, $topic,
            $SMTO_ABORTIFHUNG, 1000, [ref]$res)
    }
}

# PowerToys only reads its enabled-modules list at startup, so a module we
# disable on disk keeps running until the runner is restarted.
function Restart-PowerToys {
    # We may have stopped it already to edit its config, so fall back to the
    # install path rather than relying on a running process.
    $exe = (Get-Process PowerToys -ErrorAction SilentlyContinue | Select-Object -First 1).Path
    if (-not $exe) { $exe = Join-Path $env:LOCALAPPDATA 'PowerToys\PowerToys.exe' }
    if (-not (Test-Path $exe)) { return }

    Stop-LockingProcess -Pattern 'PowerToys*'
    Start-Process $exe
}

function Restart-Explorer {
    # Explorer relaunches itself, so this only blips the taskbar. Desktop icons
    # and open Explorer windows come back; other apps are untouched.
    Get-Process explorer -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe
    }
}

function Get-TweakList {
    param([string]$ManifestPath)

    if (-not (Test-Path $ManifestPath)) {
        Write-Warn "tweaks - manifest not found ($ManifestPath)"
        return @()
    }
    $json = Get-Content $ManifestPath -Raw | ConvertFrom-Json

    $out = @()
    $index = 0
    foreach ($prop in $json.PSObject.Properties) {
        if ($prop.Name -like '$*') { continue }   # skip $comment
        foreach ($t in $prop.Value) {
            $out += [pscustomobject]@{
                Group      = $prop.Name
                Index      = $index++
                Id         = $t.id
                Name       = $t.name
                Default    = [bool]$t.default
                Refresh    = $(if ($t.refresh) { $t.refresh } else { 'none' })
                RefreshNow = [bool]$t.refreshNow
                Requires   = @($t.requires)
                Settings   = $t.settings
                Pins       = $t.pins
            }
        }
    }
    return $out
}

# Is every registry value for this tweak already at its desired state?
# Settings live in two kinds of place: the registry, and app config files that
# happen to be JSON. Both are addressed the same way from the manifest, so a
# tweak can mix them.

function Resolve-SettingFile {
    param([string]$Path)
    [Environment]::ExpandEnvironmentVariables($Path)
}

# Walk a dot-delimited path such as 'enabled.LightSwitch'.
function Get-JsonNode {
    param([object]$Root, [string]$Key)

    $node = $Root
    $parts = $Key -split '\.'
    foreach ($p in $parts[0..($parts.Count - 2)]) {
        if ($null -eq $node -or -not $node.PSObject.Properties[$p]) { return $null }
        $node = $node.$p
    }
    [pscustomobject]@{ Parent = $node; Leaf = $parts[-1] }
}

# Create any missing intermediate objects so a key can be set on a config file
# that doesn't have that section yet.
function Add-JsonPath {
    param([object]$Root, [string]$Key)

    if ($null -eq $Root) { $Root = [pscustomobject]@{} }
    $node  = $Root
    $parts = $Key -split '\.'
    foreach ($p in $parts[0..($parts.Count - 2)]) {
        if (-not $node.PSObject.Properties[$p] -or $null -eq $node.$p) {
            $node | Add-Member -NotePropertyName $p -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        $node = $node.$p
    }
    return $Root
}

function Stop-LockingProcess {
    param([string]$Pattern)

    $procs = Get-Process -Name $Pattern -ErrorAction SilentlyContinue
    if (-not $procs) { return }
    $procs | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 1500
}

function Test-SettingApplied {
    param([pscustomobject]$Setting)

    if ($Setting.kind -eq 'json') {
        $file = Resolve-SettingFile $Setting.file
        # A missing file usually means the app isn't installed. But if its
        # config directory exists the app is here and simply hasn't written
        # settings yet - and its defaults are what we're overriding.
        if (-not (Test-Path $file)) {
            return -not (Test-Path (Split-Path $file -Parent))
        }
        $raw = Get-Content $file -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
        $node = Get-JsonNode -Root ($raw | ConvertFrom-Json) -Key $Setting.key
        if ($null -eq $node -or $null -eq $node.Parent) { return $false }
        if (-not $node.Parent.PSObject.Properties[$node.Leaf]) { return $false }
        return $node.Parent.($node.Leaf) -eq $Setting.value
    }

    if (-not (Test-Path $Setting.path)) { return $false }
    $item = Get-ItemProperty -Path $Setting.path -Name $Setting.name -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $false }
    return $item.($Setting.name) -eq $Setting.value
}

function Set-Setting {
    param([pscustomobject]$Setting)

    if ($Setting.kind -eq 'json') {
        $file = Resolve-SettingFile $Setting.file
        if (-not (Test-Path (Split-Path $file -Parent))) { return }   # app absent

        # An app that owns this file may hold it open and will also overwrite
        # our edit from memory when it exits, so close it first.
        if ($Setting.lockedBy) { Stop-LockingProcess -Pattern $Setting.lockedBy }

        $raw  = if (Test-Path $file) { Get-Content $file -Raw } else { '' }
        $json = if ([string]::IsNullOrWhiteSpace($raw)) { [pscustomobject]@{} }
                else { $raw | ConvertFrom-Json }
        $node = Get-JsonNode -Root $json -Key $Setting.key
        if ($null -eq $node -or $null -eq $node.Parent) {
            $json = Add-JsonPath -Root $json -Key $Setting.key
            $node = Get-JsonNode -Root $json -Key $Setting.key
        }

        if ($node.Parent.PSObject.Properties[$node.Leaf]) { $node.Parent.($node.Leaf) = $Setting.value }
        else { $node.Parent | Add-Member -NotePropertyName $node.Leaf -NotePropertyValue $Setting.value }

        # Match the file's existing shape so we don't reformat someone's config.
        $out = if ($raw -match "`n") { $json | ConvertTo-Json -Depth 32 }
               else                  { $json | ConvertTo-Json -Depth 32 -Compress }
        if ([string]::IsNullOrWhiteSpace($out)) { throw "refusing to write empty content to $file" }

        # Write via a temp file and swap it in: a failed or partial write can
        # never leave the real config truncated.
        $tmp = "$file.dotfiles-tmp"
        Set-Content -Path $tmp -Value $out -Encoding UTF8 -NoNewline
        Move-Item -Path $tmp -Destination $file -Force
        return
    }

    if (-not (Test-Path $Setting.path)) { New-Item -Path $Setting.path -Force | Out-Null }
    New-ItemProperty -Path $Setting.path -Name $Setting.name -Value $Setting.value `
                     -PropertyType $Setting.type -Force | Out-Null
}

# --- Taskbar pins -----------------------------------------------------------
# Windows 11 has no API for pinning, and the old Taskband registry blob is not
# reliable. The supported route is a LayoutModification.xml: Explorer re-reads
# it when the file is newer than Taskband\LayoutXMLLastModified, which is what
# makes this work on a profile that already exists.
#
# Note this declares the ENTIRE pin list (PinListPlacement="Replace"), so
# anything not listed gets unpinned.

$script:TaskbarLayoutPath = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Shell\LayoutModification.xml'

# Each pin lists candidate .lnk paths (first one present wins) or an AUMID for
# Store apps, which have no shortcut. An app that isn't installed is skipped
# rather than pinned to a dead target.
function Resolve-PinTarget {
    param([pscustomobject]$Pin)

    foreach ($cand in @($Pin.lnk)) {
        if (-not $cand) { continue }
        $full = [Environment]::ExpandEnvironmentVariables($cand)
        $hit  = @(Get-Item -Path $full -ErrorAction SilentlyContinue)
        if ($hit.Count) { return [pscustomobject]@{ Kind = 'lnk'; Value = $hit[0].FullName } }
    }
    if ($Pin.aumid) { return [pscustomobject]@{ Kind = 'aumid'; Value = $Pin.aumid } }
    return $null
}

function New-TaskbarLayoutXml {
    param([array]$Pins)

    $entries = @()
    foreach ($pin in $Pins) {
        $t = Resolve-PinTarget -Pin $pin
        if (-not $t) { continue }
        $entries += if ($t.Kind -eq 'aumid') {
            '        <taskbar:UWA AppUserModelID="{0}" />' -f $t.Value
        } else {
            '        <taskbar:DesktopApp DesktopApplicationLinkPath="{0}" />' -f $t.Value
        }
    }
    if (-not $entries) { return $null }

    @(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<LayoutModificationTemplate'
        '    xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"'
        '    xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout"'
        '    xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout"'
        '    xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout"'
        '    Version="1">'
        '  <CustomTaskbarLayoutCollection PinListPlacement="Replace">'
        '    <defaultlayout:TaskbarLayout>'
        '      <taskbar:TaskbarPinList>'
        $entries
        '      </taskbar:TaskbarPinList>'
        '    </defaultlayout:TaskbarLayout>'
        '  </CustomTaskbarLayoutCollection>'
        '</LayoutModificationTemplate>'
    ) -join "`r`n"
}

function Test-PinsApplied {
    param([pscustomobject]$Tweak)

    $wanted = New-TaskbarLayoutXml -Pins $Tweak.Pins
    if (-not $wanted) { return $true }              # nothing installed to pin
    if (-not (Test-Path $script:TaskbarLayoutPath)) { return $false }
    $have = Get-Content $script:TaskbarLayoutPath -Raw
    return ($have -replace "`r`n", "`n").Trim() -eq ($wanted -replace "`r`n", "`n").Trim()
}

function Set-Pins {
    param([pscustomobject]$Tweak)

    $xml = New-TaskbarLayoutXml -Pins $Tweak.Pins
    if (-not $xml) { throw 'none of the apps to pin are installed' }

    $dir = Split-Path $script:TaskbarLayoutPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Set-Content -Path $script:TaskbarLayoutPath -Value $xml -Encoding UTF8
}

function Test-TweakApplied {
    param([pscustomobject]$Tweak)

    if ($Tweak.Pins) { return Test-PinsApplied -Tweak $Tweak }
    foreach ($s in $Tweak.Settings) {
        if (-not (Test-SettingApplied -Setting $s)) { return $false }
    }
    return $true
}

function Set-Tweak {
    param([pscustomobject]$Tweak)

    if ($Tweak.Pins) { Set-Pins -Tweak $Tweak; return }
    foreach ($s in $Tweak.Settings) { Set-Setting -Setting $s }
}

<#
    Apply tweaks from the manifest.

    -Only     apply just these ids (overrides the default flag)
    -Groups   restrict to these manifest groups
    -All      include tweaks marked default:false
    -Preview  report what would change, write nothing
#>
function Invoke-Refresh {
    param([string]$Kind)

    switch ($Kind) {
        'explorer'      { Restart-Explorer }
        'settingchange' { Publish-SettingChange }
        'powertoys'     { Restart-PowerToys }
    }
}

function Invoke-WindowsTweaks {
    param(
        [string]   $ManifestPath,
        [string[]] $Only,
        [string[]] $Groups,
        [switch]   $All,
        [switch]   $Preview
    )

    $catalog = Get-TweakList -ManifestPath $ManifestPath
    if (-not $catalog) { return }
    $tweaks = $catalog

    if ($Groups) { $tweaks = $tweaks | Where-Object { $Groups -contains $_.Group } }
    if ($Only)   { $tweaks = $tweaks | Where-Object { $Only   -contains $_.Id } }
    elseif (-not $All) { $tweaks = $tweaks | Where-Object { $_.Default } }
    $tweaks = @($tweaks)

    if (-not $tweaks) { Write-Info 'tweaks - nothing selected'; return }

    # Pull in prerequisites, then run in manifest order so a tweak that clears
    # the way for another (disabling an app that fights it) goes first.
    $selected = @{}; foreach ($t in $tweaks) { $selected[$t.Id] = $true }
    foreach ($t in @($tweaks)) {
        foreach ($req in $t.Requires) {
            if (-not $req -or $selected[$req]) { continue }
            $dep = @($catalog | Where-Object { $_.Id -eq $req })
            if ($dep) { $tweaks += $dep[0]; $selected[$req] = $true }
        }
    }
    $tweaks = $tweaks | Sort-Object Index

    $refreshes = @{}
    foreach ($t in $tweaks) {
        if (Test-TweakApplied -Tweak $t) {
            Write-Info "$($t.Name) - already set"
            continue
        }
        if ($Preview) {
            Write-Info "$($t.Name) - WOULD apply"
            continue
        }
        try {
            Set-Tweak -Tweak $t
            Write-Ok $t.Name
            if ($t.Refresh -eq 'none') { continue }
            # Prerequisites must take effect before the next tweak is written.
            if ($t.RefreshNow) { Invoke-Refresh -Kind $t.Refresh }
            else { $refreshes[$t.Refresh] = $true }
        } catch {
            Write-Warn "$($t.Name) - failed: $($_.Exception.Message)"
        }
    }

    if ($Preview -or -not $refreshes.Count) { return }

    # An Explorer restart also picks up the theme change, so don't do both.
    if ($refreshes['explorer']) {
        Write-Info 'restarting Explorer to apply taskbar and shell changes'
        Invoke-Refresh -Kind 'explorer'
    } elseif ($refreshes['settingchange']) {
        Invoke-Refresh -Kind 'settingchange'
    }
    if ($refreshes['powertoys']) { Invoke-Refresh -Kind 'powertoys' }
}
