#!/usr/bin/env bash
set -euo pipefail

GUIX_VERSION=1.5.0
GUIX_ARCH=x86_64-linux
GUIX_SHA256=aa41025489c5061543e9c48873eaa829b900b2da75d40f9648913622f5f47817
INSTALLER_COMMIT=7fd75725c5daf9d3bdfd9122dcdb37f650493d18
INSTALLER_SHA256=6af18bee988c9e90c2bdecaf3b8880f544c38070d949ef5e52717eb71b046bbc

archive="guix-binary-${GUIX_VERSION}.${GUIX_ARCH}.tar.xz"
archive_url="https://ftp.gnu.org/gnu/guix/${archive}"
installer_url="https://codeberg.org/guix/guix/raw/commit/${INSTALLER_COMMIT}/etc/guix-install.sh"
work_dir=$(mktemp --directory "${RUNNER_TEMP:-/tmp}/guix-install.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

for command in bash curl getent gpg groupadd newgidmap nologin sha256sum sudo \
  systemctl tar useradd wget xz; do
  command -v "$command" >/dev/null || {
    printf 'required command not found: %s\n' "$command" >&2
    exit 1
  }
done

if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
  printf 'unsupported build runner: %s/%s\n' "$(uname -s)" "$(uname -m)" >&2
  exit 1
fi

curl_args=(
  --fail
  --location
  --show-error
  --silent
  --retry 5
  --retry-all-errors
  --retry-delay 2
  --connect-timeout 20
  --max-time 600
)

curl "${curl_args[@]}" --output "$work_dir/$archive" "$archive_url"
printf '%s  %s\n' "$GUIX_SHA256" "$work_dir/$archive" \
  | sha256sum --check --strict

curl "${curl_args[@]}" --output "$work_dir/guix-install.sh" "$installer_url"
printf '%s  %s\n' "$INSTALLER_SHA256" "$work_dir/guix-install.sh" \
  | sha256sum --check --strict
chmod +x "$work_dir/guix-install.sh"

{ yes '' 2>/dev/null || true; } \
  | sudo env GUIX_BINARY_FILE_NAME="$work_dir/$archive" \
      "$work_dir/guix-install.sh"

# Ubuntu 24.04 otherwise denies the user namespaces used by Guix commands.
if [[ -f /sys/module/apparmor/parameters/enabled ]] \
  && command -v apparmor_parser >/dev/null; then
  cat > "$work_dir/guix.apparmor" <<'EOF'
abi <abi/3.0>,
include <tunables/global>
profile guix /gnu/store/{*-guix-command,*/bin/guix-daemon,*/bin/guix,*/bin/guile} flags=(unconfined) {
  userns,
  include if exists <local/guix>
}
EOF
  sudo install --mode=0644 "$work_dir/guix.apparmor" /etc/apparmor.d/guix
  sudo apparmor_parser --warn=all --replace /etc/apparmor.d/guix
fi

guix_bin=/var/guix/profiles/per-user/root/current-guix/bin
printf '%s\n' "$guix_bin" >> "$GITHUB_PATH"
export PATH="$guix_bin:$PATH"

sudo systemctl is-active --quiet guix-daemon.service
guix --version
