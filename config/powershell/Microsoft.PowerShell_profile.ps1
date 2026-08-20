$env:DOTNET_ROOT = "C:\Program Files\dotnet"

# Add Git usr/bin to PATH (provides grep, awk, sed, etc.)
$env:PATH = "C:\Program Files\Git\usr\bin;$env:PATH"

$env:COLORTERM = "truecolor"

# Vim. Resolve at runtime: the install location differs per machine, and a
# hardcoded path silently breaks `vim` everywhere it does not exist.
# Clear stale values first - they are inherited by child processes, so a bad
# VIMRUNTIME from a parent shell would keep breaking vim even after this fix.
# A VIMRUNTIME pointing at a missing directory is worse than none at all: vim
# loads no runtime files, stays 'compatible', and then errors on the system
# vimrc's line continuations (E10).
foreach ($__v in 'VIM', 'VIMRUNTIME', 'VIM_EXE') {
    $__cur = [Environment]::GetEnvironmentVariable($__v)
    if ($__cur -and -not (Test-Path $__cur)) {
        # Remove-Item genuinely deletes it. [Environment]::SetEnvironmentVariable(x, $null)
        # does not work from PowerShell: $null marshals to "" and leaves the
        # variable defined-but-empty, which vim treats as a real (broken) value.
        Remove-Item "Env:$__v" -ErrorAction SilentlyContinue
    }
}

$__vimHome = @(
    "$env:LOCALAPPDATA\Programs\Vim"
    "$env:ProgramFiles\Vim"
    "${env:ProgramFiles(x86)}\Vim"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

if ($__vimHome) {
    # Vim ships as <home>\vim91\vim.exe; fall back to <home>\vim.exe.
    $__vimExe = Get-ChildItem -Path $__vimHome -Filter vim.exe -Recurse -Depth 1 -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty FullName
    if ($__vimExe) {
        $env:VIM_EXE = $__vimExe
        $__vimDir = Split-Path $__vimExe -Parent
        $env:VIM = $__vimHome
        if (Test-Path "$__vimDir\..\runtime") { $env:VIMRUNTIME = (Resolve-Path "$__vimDir\..\runtime").Path }
        elseif (Test-Path "$__vimDir\runtime") { $env:VIMRUNTIME = "$__vimDir\runtime" }
        if ($env:PATH -notlike "*$__vimDir*") { $env:PATH = "$env:PATH;$__vimDir" }
    }
}
if (-not $env:VIM_EXE) {
    # Not in a standard location - fall back to whatever is on PATH.
    $__onPath = Get-Command vim.exe -ErrorAction SilentlyContinue
    if ($__onPath) { $env:VIM_EXE = $__onPath.Source }
}

# The cheat-sheet split is drawn by vim itself (_vimrc -> OpenCheatSheet, toggled
# with :Cheat or <Space>c). Do NOT recreate it with a Windows Terminal split-pane:
# that gives two separate shells, and vim would then draw its own split inside the
# left one anyway. `leet` just opens a practice file in normal vim.
function leet {
    param([string]$file = "pract.py")
    if (!(Test-Path $file)) { New-Item -ItemType File -Path $file | Out-Null }
    if ($env:VIM_EXE) { & $env:VIM_EXE (Resolve-Path $file).Path } else { vim $file }
}

# ===========================================================================
#  Aesthetics + tooling  (Oh My Posh + PSReadLine + zoxide/fzf/eza/bat)
#  Subprocess init output is cached to ~\.cache\pwsh and regenerated only
#  when the underlying tool or theme changes, which keeps startup fast.
# ===========================================================================
if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {

    $__cacheDir = "$HOME\.cache\pwsh"
    if (-not (Test-Path $__cacheDir)) { New-Item -ItemType Directory -Force -Path $__cacheDir | Out-Null }

    # Dot-source a cached init script, regenerating it only when a dependency is newer.
    function Use-CachedInit {
        param(
            [string]   $Name,
            [string[]] $DependsOn,
            [scriptblock] $Generator
        )
        $cache = Join-Path $__cacheDir "$Name.ps1"
        $newestDep = ($DependsOn | Where-Object { $_ -and (Test-Path $_) } |
                      ForEach-Object { (Get-Item $_).LastWriteTimeUtc } |
                      Sort-Object -Descending | Select-Object -First 1)
        $stale = -not (Test-Path $cache)
        if (-not $stale -and $newestDep) {
            $stale = (Get-Item $cache).LastWriteTimeUtc -lt $newestDep
        }
        if ($stale) {
            try { (& $Generator | Out-String) | Set-Content $cache -Encoding utf8 } catch { return }
        }
        . $cache
    }

    # --- Starship prompt (Tokyo Night) ---
    # Chosen over oh-my-posh: this machine has slow process creation (~50-120ms
    # per spawn), and starship renders in ~70ms vs oh-my-posh's ~170ms.
    # Test-Path the known location first: a Get-Command miss scans all of PATH
    # and costs ~220ms on this machine.
    $__starship = "$env:ProgramFiles\starship\bin\starship.exe"
    if (Test-Path $__starship) {
        if ($env:PATH -notlike "*starship\bin*") {
            $env:PATH = "$env:PATH;$env:ProgramFiles\starship\bin"
        }
    } else {
        $__starship = (Get-Command starship -ErrorAction SilentlyContinue).Source
    }
    if ($__starship) {
        $env:STARSHIP_CONFIG = "$HOME\.config\starship.toml"
        Use-CachedInit 'starship' @($__starship) { & $__starship init powershell --print-full-init }
    }

    # --- zoxide: `z <partial>` jumps to your most-used matching dir, `zi` picks interactively ---
    $__zoxide = (Get-Command zoxide -ErrorAction SilentlyContinue).Source
    if ($__zoxide) {
        Use-CachedInit 'zoxide' @($__zoxide) { zoxide init powershell --cmd z }
    }

    # --- PSReadLine: predictions + Tokyo Night syntax colors ---
    # ListView shows history/plugin suggestions as a dropdown list under the prompt.
    # It throws if the console has no virtual-terminal support (some remote or
    # redirected hosts), so fall back to inline rather than erroring at startup.
    Import-Module PSReadLine -ErrorAction SilentlyContinue
    try {
        Set-PSReadLineOption -PredictionSource HistoryAndPlugin -PredictionViewStyle ListView
    } catch {
        try { Set-PSReadLineOption -PredictionSource History } catch { }
    }
    Set-PSReadLineOption -HistorySearchCursorMovesToEnd
    Set-PSReadLineOption -Colors @{
        Command            = "#7aa2f7"
        Parameter          = "#bb9af7"
        Operator           = "#89ddff"
        Variable           = "#d5dcf8"
        String             = "#9ece6a"
        Number             = "#ff9e64"
        Type               = "#7dcfff"
        Comment            = "#8b96c0"
        Keyword            = "#bb9af7"
        Error              = "#f7768e"
        InlinePrediction   = "#8b96c0"
        ListPrediction     = "#7aa2f7"
        # Selection and the MenuComplete highlight are BACKGROUND highlights, but
        # PSReadLine reads a bare "#rrggbb" as a FOREGROUND colour. Passing a hex
        # here painted the selected text dark on the dark background, so the
        # highlighted item was unreadable. Give the full escape instead: black
        # background, bright Tokyo Night foreground.
        # Background only, no foreground: Windows Terminal's mouse selection
        # keeps the syntax colours and only swaps the background, so forcing a
        # flat foreground here made keyboard selection look different from
        # dragging with the mouse. Keep in sync with selectionBackground.
        Selection                = "`e[48;2;58;58;58m"
        ListPredictionSelected   = "`e[48;2;58;58;58m"
    }

    # The colours above are the built-in fallback. bootstrap.ps1 -Theme writes
    # the selected theme here, dot-sourced last so it wins - that way switching
    # themes never has to rewrite this profile.
    $__theme = Join-Path $HOME '.config\pwsh\theme.ps1'
    if (Test-Path $__theme) { . $__theme }

    # Arrow keys walk through history matches for what you've typed    Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
    # Tab = menu-style completion
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete

    # --- fzf via PSFzf, imported on first keypress (the module costs ~500ms to load) ---
    $env:FZF_DEFAULT_OPTS = '--height=45% --layout=reverse --border=rounded --info=inline ' +
        '--color=bg+:#283457,bg:-1,spinner:#bb9af7,hl:#7aa2f7 ' +
        '--color=fg:#c0caf5,header:#7aa2f7,info:#e0af68,pointer:#bb9af7 ' +
        '--color=marker:#9ece6a,fg+:#c0caf5,prompt:#bb9af7,hl+:#7dcfff'

    $__initFzf = {
        if (-not (Get-Module PSFzf)) {
            Import-Module PSFzf -ErrorAction SilentlyContinue
            # This re-binds Ctrl+t / Ctrl+r to PSFzf's own handlers, so this
            # bootstrap only ever runs once per session.
            Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r'
        }
    }
    Set-PSReadLineKeyHandler -Chord 'Ctrl+t' -ScriptBlock {
        & $__initFzf; Invoke-FzfPsReadlineHandlerProvider
    }.GetNewClosure()
    Set-PSReadLineKeyHandler -Chord 'Ctrl+r' -ScriptBlock {
        & $__initFzf; Invoke-FzfPsReadlineHandlerHistory
    }.GetNewClosure()

    # --- eza: modern ls with icons + git status ---
    # eza on Windows returns nothing unless a path is passed explicitly, so default to '.'
    if (Get-Command eza -ErrorAction SilentlyContinue) {
        function Invoke-Eza {
            param([string[]]$EzaOpts, [string[]]$UserArgs)
            $hasPath = @($UserArgs | Where-Object { $_ -notmatch '^-' }).Count -gt 0
            $final = @($EzaOpts) + @($UserArgs) + $(if ($hasPath) { @() } else { @('.') })
            eza @final
        }
        Remove-Item Alias:ls -Force -ErrorAction SilentlyContinue
        function ls { Invoke-Eza @('--icons','--group-directories-first') $args }
        function ll { Invoke-Eza @('--icons','--group-directories-first','-l','--git','--time-style=long-iso') $args }
        function la { Invoke-Eza @('--icons','--group-directories-first','-la','--git','--time-style=long-iso') $args }
        function lt { Invoke-Eza @('--icons','--group-directories-first','--tree','--level=2') $args }
    }

    # --- bat: cat with syntax highlighting ---
    if (Get-Command bat -ErrorAction SilentlyContinue) {
        $env:BAT_THEME = 'Coldark-Dark'
        function cat { bat --style=numbers,changes @args }
    }

    # --- Completions (cached; gh shells out, winget is registered inline) ---
    $__gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
    if ($__gh) {
        Use-CachedInit 'gh' @($__gh) { gh completion -s powershell }
    }
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Register-ArgumentCompleter -Native -CommandName winget -ScriptBlock {
            param($wordToComplete, $commandAst, $cursorPosition)
            [Console]::InputEncoding = [Console]::OutputEncoding = $OutputEncoding = [System.Text.Utf8Encoding]::new()
            winget complete --word "$wordToComplete" --commandline "$commandAst" --position $cursorPosition |
                ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
        }
    }
}


# ---------------------------------------------------------------------------
# Machine-local overrides. Not in this repo, and never committed: this is where
# work-specific build helpers, internal paths and per-machine tweaks live.
# Create ~/.config/pwsh/local.ps1 and it gets sourced last, so it can override
# anything above.
# ---------------------------------------------------------------------------
$__local = Join-Path $HOME '.config\pwsh\local.ps1'
if (Test-Path $__local) { . $__local }
