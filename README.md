# dotfiles

Windows terminal environment: PowerShell 7 profile, Starship prompt, Windows
Terminal, Neovim and winget settings.

## New machine

```powershell
git clone https://github.com/Shivam60/dotfiles.git $HOME\dotfiles
cd $HOME\dotfiles
.\bootstrap.ps1              # install packages + apply configs
.\bootstrap.ps1 -IncludeApps # also install browsers, PowerToys, Obsidian, etc.
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

## What's in here

| Path | Goes to |
| --- | --- |
| `config/powershell/Microsoft.PowerShell_profile.ps1` | `$PROFILE` |
| `config/starship/starship.toml` | `~/.config/starship.toml` |
| `config/windows-terminal/settings.json` | `…/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/` |
| `config/winget/settings.json` | `…/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe/LocalState/` |
| `config/nvim/init.lua` | `%LOCALAPPDATA%\nvim\init.lua` |

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
