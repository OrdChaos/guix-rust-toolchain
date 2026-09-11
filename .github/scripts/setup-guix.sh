#!/bin/sh
set -eu

project_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)

sudo apt-get update
sudo apt-get install --no-install-recommends --yes ca-certificates curl guix
sudo systemctl start guix-daemon.service
sudo systemctl is-active --quiet guix-daemon.service

guix pull -C "$project_root/.github/guix-channels.scm"
current_guix="$HOME/.config/guix/current/bin"
printf '%s\n' "$current_guix" >> "$GITHUB_PATH"
"$current_guix/guix" --version
