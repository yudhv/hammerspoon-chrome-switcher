#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_file="$repo_dir/init.lua"
target_dir="$HOME/.hammerspoon"
target_file="$target_dir/init.lua"
backup_dir="$target_dir/backups"

if [[ ! -f "$source_file" ]]; then
  echo "Missing $source_file" >&2
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required to install Hammerspoon automatically." >&2
  echo "Install Homebrew first, then re-run this script." >&2
  exit 1
fi

if [[ ! -d /Applications/Hammerspoon.app ]]; then
  brew install --cask hammerspoon
fi

mkdir -p "$target_dir" "$backup_dir"

if [[ -f "$target_file" ]] && ! cmp -s "$source_file" "$target_file"; then
  stamp="$(date +%Y%m%d%H%M%S)"
  cp "$target_file" "$backup_dir/init.lua.$stamp"
fi

if [[ ! -f "$target_file" ]] || ! cmp -s "$source_file" "$target_file"; then
  cp "$source_file" "$target_file"
  echo "Installed $target_file"
else
  echo "$target_file is already up to date"
fi

if command -v luac >/dev/null 2>&1; then
  luac -p "$target_file"
fi

open -a Hammerspoon
sleep 1

if command -v hs >/dev/null 2>&1; then
  hs -c 'hs.reload(); return true' >/dev/null 2>&1 || true
fi

echo "Done. If shortcuts do not work, enable Hammerspoon in System Settings > Privacy & Security > Accessibility."
