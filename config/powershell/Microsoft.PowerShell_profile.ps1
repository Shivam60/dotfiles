if (Test-Path C:\REDACTED_PROJECT\src) { Set-Location C:\REDACTED_PROJECT\src }
$env:DOTNET_ROOT = "C:\Program Files\dotnet"

# Add Git usr/bin to PATH (provides grep, awk, sed, etc.)
$env:PATH = "C:\Program Files\Git\usr\bin;$env:PATH"

# REDACTED_PROJECT Build Aliases
$env:MSBUILD = "C:\Program Files\Microsoft Visual Studio\18\Enterprise\MSBuild\Current\Bin\MSBuild.exe"
$SLNDIR = "C:\REDACTED_PROJECT\src\"
$REDACTED_APP_PROJ = "C:\REDACTED_PROJECT\src\REDACTED_APP\REDACTED_APP.vcxproj"
$REDACTED_PACKAGE_PROJ = "C:\REDACTED_PROJECT\src\REDACTED_PACKAGE\REDACTED_PACKAGE.wapproj"
$COMMON_PROPS = @("/p:Configuration=Debug", "/p:Platform=x64", "/p:SolutionDir=$SLNDIR", "/p:VcpkgEnableManifest=false", "/v:minimal")

# Resolve vcxproj and relative file path. Add new elseif branches here to support more projects.
function Get-VcxProj($file) {
    if ($file -match 'REDACTED_LIB[\\\/]') { return "C:\REDACTED_PROJECT\src\REDACTED_LIB\REDACTED_LIB.vcxproj" }
    # Default: REDACTED_APP
    return $REDACTED_APP_PROJ
}

# Extract file path relative to its project folder (e.g. Telemetry\Foo.cpp from REDACTED_LIB\Telemetry\Foo.cpp)
function Get-SelectedFile($file) {
    if ($file -match '(?i)REDACTED_LIB[\\\/](.+)$') { return $matches[1] }
    if ($file -match '(?i)REDACTED_APP[\\\/](.+)$') { return $matches[1] }
    return Split-Path $file -Leaf
}

# Compile a single file with optional code analysis
function Invoke-CompileFile($file, [bool]$codeAnalysis = $false) {
    if (!(Test-Path $file)) { Write-Host "File not found: $file" -ForegroundColor Red; return }
    $absPath = (Resolve-Path $file).Path
    $proj = Get-VcxProj $absPath
    $sel = Get-SelectedFile $absPath
    Write-Host "Project: $proj | File: $absPath" -ForegroundColor Cyan
    & $env:MSBUILD $proj $COMMON_PROPS /t:ClCompile /p:SelectedFiles=$sel /p:BuildProjectReferences=false /p:RunCodeAnalysis=$codeAnalysis
}

# Compile a single file (fastest, no link, no analysis)
function compile($file) { Invoke-CompileFile $file $false }

# Compile a single file with Code Analysis (matches CI)
function analyze($file) { Invoke-CompileFile $file $true }

# Build REDACTED_APP (compile + link, no deploy)
function build { & $env:MSBUILD $REDACTED_APP_PROJ $COMMON_PROPS }

# Build + package + deploy as MSIX app
function deploy { & $env:MSBUILD $REDACTED_PACKAGE_PROJ $COMMON_PROPS }

# Clean build artifacts (removes obj, bin folders)
function clean { & $env:MSBUILD $REDACTED_APP_PROJ /t:Clean $COMMON_PROPS }

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
        Variable           = "#c0caf5"
        String             = "#9ece6a"
        Number             = "#ff9e64"
        Type               = "#7dcfff"
        Comment            = "#565f89"
        Keyword            = "#bb9af7"
        Error              = "#f7768e"
        InlinePrediction   = "#565f89"
        ListPrediction     = "#7aa2f7"
        Selection          = "#283457"
    }

    # Arrow keys walk through history matches for what you've typed
    Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
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

