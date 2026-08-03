# dotfiles

Windows terminal environment: PowerShell 7 profile, Starship prompt, Windows
Terminal, Neovim and winget settings.

## New machine

```powershell
git clone https://github.com/Shivam60/dotfiles.git $HOME\dotfiles
cd $HOME\dotfiles
.\bootstrap.ps1              # asks what you want, then does it
```

Run with no arguments and it prompts:

```
  [1] Full setup          - install packages, then apply configs
  [2] Apply configs only  - terminal, prompt, git, nvim (no installing)
  [3] Install packages    - pick exactly which ones
  [4] Capture configs     - copy my local edits back into this repo
  [5] Preview             - show what Apply would change, write nothing
```

Choosing *Install* then offers essentials / everything / pick-individually, where
you toggle packages by number (`2`, `4-6`, `a`, `n`, Enter to accept).

The switches still work for scripted runs, and the menu is skipped automatically
when stdin is not a terminal:

```powershell
.\bootstrap.ps1 -Install -Apply             # what the old default did
.\bootstrap.ps1 -Install -Only sharkdp.bat,GitHub.cli
.\bootstrap.ps1 -Install -Groups shell      # one group only
.\bootstrap.ps1 -NonInteractive -Apply      # never prompt
```

Then open a **new** terminal tab.

## Day to day

```powershell
git pull; .\bootstrap.ps1 -Apply    # take changes from the repo
.\bootstrap.ps1 -Capture            # put local edits back into the repo
git diff; git commit -am "..."; git push
```

`-WhatIfCopy` previews either direction without writing.

## Installing packages

`-Install` figures out what is already present *before* touching winget, using
the first cheap signal that works:

1. `font` — is the family already registered? (fonts are often installed by hand)
2. `probe` — does the command or path resolve? Catches tools installed by scoop,
   chocolatey, an MSI or the corp image, which winget knows nothing about.
3. `altIds` — a different package that satisfies the same need.
4. Only then, one `winget list` call (~5s), matched on whole tokens so
   `Microsoft.Edge` cannot falsely match `Microsoft.Edge.Canary`.

If nothing is missing, no elevation happens at all. If something *is* missing,
the script elevates **once** for the whole batch rather than letting winget raise
a UAC prompt per package. `-NoElevate` opts out.

> `Git.Git` has `probe: git` and `altIds: [Microsoft.Git]` on purpose. Corp
> monorepo machines run the VFS-for-Git fork (`Microsoft.Git`), and installing
> stock Git over it would shadow it on `PATH`.

## Dev boxes and RDP

Windows Terminal renders on the machine you RDP *into*, so the font and configs
must be installed **there**, not on your laptop:

```powershell
git clone https://github.com/Shivam60/dotfiles.git $HOME\dotfiles
cd $HOME\dotfiles
.\bootstrap.ps1 -Apply -RdpTweaks
```

Two things differ in a remote session:

- **Fonts.** winget's font package needs admin, which dev boxes often withhold.
  `-Install` falls back to downloading the Nerd Font and registering it under
  `HKCU` + `%LOCALAPPDATA%\Microsoft\Windows\Fonts`, which needs no elevation and
  takes effect immediately. Without the font every glyph renders as a box.
- **Transparency.** `useAcrylic` is the frosted-*blur* effect and relies on local
  hardware composition, so it never renders over RDP. Plain `opacity` is only an
  alpha value on the window and works remotely on Windows 11 — but plenty of RDP
  clients drop alpha too, and Windows 10 cannot do it at all. So `-RdpTweaks`
  keeps the opacity in case it works, and *also* applies a generated Tokyo Night
  gradient as a background image. Windows Terminal draws that itself instead of
  asking the desktop compositor, so it always survives the remote session and
  restores some of the depth the blur used to give.

The image is copied into Windows Terminal's `LocalState` and referenced as
`ms-appdata:///local/bg-tokyonight.png`, so the setting stays valid wherever the
repo lives.

`-RdpTweaks` patches only the live file; the repo copy stays canonical for local
machines. Don't `-Capture` on a dev box afterwards, or you'll commit the tweak.

## What's in here

| Path | Goes to |
| --- | --- |
| `config/powershell/Microsoft.PowerShell_profile.ps1` | `$PROFILE` |
| `config/starship/starship.toml` | `~/.config/starship.toml` |
| `config/windows-terminal/settings.json` | `…/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/` |
| `config/winget/settings.json` | `…/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe/LocalState/` |
| `config/nvim/init.lua` | `%LOCALAPPDATA%\nvim\init.lua` |
| `config/git/shared.gitconfig` | *included* from `~/.gitconfig` (not copied) |

### git config is split on purpose

`~/.gitconfig` holds corp identity, credential endpoints and an AAD tenant ID —
none of which belong on GitHub. So only the portable half (delta styling, diff
settings, aliases, lfs, merge behaviour) is committed here, and `bootstrap.ps1`
adds a single `include.path` line at the *top* of `~/.gitconfig`. Because the
include comes first, anything defined locally still overrides it.

Note `git config --global --get X` will not show included values — that flag
scopes the lookup to one file. Use `git config --get X` instead.

Packages live in `packages.json`, grouped as `fonts` / `shell` / `dev` / `apps`
(`apps` is opt-in via `-IncludeApps`). Add an id there, not in the script.

## Why files are copied, not symlinked

**Windows Terminal silently ignores a symlinked `settings.json`** and falls back
to its built-in defaults — no error, no warning. A previous OneDrive symlink
setup looked correct on disk while Windows Terminal had never once read it, so
the font and colour scheme never applied.

`bootstrap.ps1` therefore copies, and replaces any symlink it finds at a
destination. Every overwrite is backed up next to the original as `*.bak-<timestamp>`.

## Notes

- Shell history is **not** synced — it can contain tokens and internal hostnames.
- The prompt needs a Nerd Font. `packages.json` installs JetBrainsMono Nerd Font;
  Windows Terminal must reference the DirectWrite family name
  `JetBrainsMono Nerd Font Mono` (not the GDI name `JetBrainsMono NFM`), or it
  falls back and every glyph renders as a box.
- The profile caches `starship`/`zoxide`/`gh` init output under `~/.cache/pwsh`
  and regenerates it when the tool binary changes. Delete that folder to force a
  rebuild.
- `PSFzf` is imported on first `Ctrl+t`/`Ctrl+r` rather than at startup.
