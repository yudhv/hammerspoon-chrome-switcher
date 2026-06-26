# Hammerspoon Chrome Switcher

Arc-style Chrome tab switcher for macOS.

## What It Does

- `Ctrl-Tab` opens a compact Chrome tab/search palette.
- Repeated `Ctrl-Tab` moves down the list.
- `Ctrl-Shift-Tab` moves up the list.
- Releasing `Ctrl` opens the selected item only after you have cycled.
- A single `Ctrl-Tab` press opens the palette and leaves it open for typing.
- `Ctrl-J` / `Ctrl-K` move down/up while the palette is open.
- Results prefer current Chrome tabs, then recent Chrome history, then Google search.
- Rows show favicons and compact labels like `Tab • youtube.com`.

## Install

```sh
git clone git@github.com:yudhv/hammerspoon-chrome-switcher.git
cd hammerspoon-chrome-switcher
./install.sh
```

Then enable Hammerspoon in:

`System Settings > Privacy & Security > Accessibility`

macOS may also ask for Automation permission so Hammerspoon can control Google Chrome.

## Re-run Safely

`./install.sh` is idempotent:

- Installs Hammerspoon only if it is missing.
- Creates `~/.hammerspoon` if needed.
- Copies `init.lua` only when it changed.
- Backs up a different existing config to `~/.hammerspoon/backups/`.
- Syntax-checks with `luac` when available.
- Opens/reloads Hammerspoon when possible.

You can re-run it after pulling updates on any machine.

## Update This Repo From This Machine

```sh
cp ~/.hammerspoon/init.lua ./init.lua
git diff
git add init.lua README.md install.sh
git commit -m "Update Chrome switcher"
git push
```

## Notes

The switcher reads open Chrome tabs through AppleScript and reads Chrome history from a temporary copy of Chrome's `History` SQLite database. It does not inspect cookies, passwords, local storage, or Chrome profile secrets.
