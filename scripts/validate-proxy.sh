#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
proxy_package=$(guix build -L "$project_root/guix" \
  -e '(begin (use-modules (rust-toolchain proxy)) %rust-toolchain-proxies)')
cache=$(mktemp -d)
project=$(mktemp -d)
trap 'rm -rf "$cache" "$project"' EXIT HUP INT TERM

proxy="$proxy_package/bin"
export XDG_CACHE_HOME="$cache"

"$proxy/cargo" +stable --version | grep '^cargo 1\.98\.1 '
"$proxy/cargo" +nightly --version | grep '^cargo 1\.100\.0-nightly '
"$proxy/cargo" +nightly-2026-09-10 --version | grep '^cargo 1\.100\.0-nightly '
RUSTUP_TOOLCHAIN=nightly "$proxy/cargo" --version \
  | grep '^cargo 1\.100\.0-nightly '
RUSTUP_TOOLCHAIN=nightly "$proxy/cargo" +stable --version \
  | grep '^cargo 1\.98\.1 '

for root in "$cache/guix-rust-toolchain/roots/"*; do
  test -L "$root"
  guix gc --list-roots | grep -F -x "$root"
done
for entry in "$cache/guix-rust-toolchain/entries/"????????????????; do
  grep '^provider:/gnu/store/.*-guix-rust-toolchain-provider$' "$entry"
  grep '^guix:/gnu/store/.*-guix-' "$entry"
done

GUIX_DAEMON_SOCKET=/does-not-exist "$proxy/cargo" +stable --version \
  | grep '^cargo 1\.98\.1 '

rm -rf "$cache/guix-rust-toolchain"
"$proxy/cargo" +stable --version | grep '^cargo 1\.98\.1 '

rm -rf "$cache/guix-rust-toolchain"
"$proxy/cargo" +stable --version > "$cache/stable.out" &
stable_pid=$!
"$proxy/cargo" +stable --version > "$cache/stable-second.out" &
stable_second_pid=$!
wait "$stable_pid"
wait "$stable_second_pid"
grep '^cargo 1\.98\.1 ' "$cache/stable.out"
grep '^cargo 1\.98\.1 ' "$cache/stable-second.out"

stable_entry=$(grep -l '^channel:stable$' \
  "$cache/guix-rust-toolchain/entries/"????????????????)
stable_name=$(basename "$stable_entry")
printf '%s\n' corrupt > "$stable_entry"
"$proxy/cargo" +stable --version | grep '^cargo 1\.98\.1 '
rm "$cache/guix-rust-toolchain/roots/$stable_name"
"$proxy/cargo" +stable --version | grep '^cargo 1\.98\.1 '

victim="$cache/symlink-victim"
printf '%s\n' unchanged > "$victim"
rm "$stable_entry" "$cache/guix-rust-toolchain/roots/$stable_name"
ln -s "$victim" "$stable_entry"
if "$proxy/cargo" +stable --version >/dev/null 2>&1; then
  printf '%s\n' "proxy followed a cache identity symlink" >&2
  exit 1
fi
grep '^unchanged$' "$victim"
rm "$stable_entry"

"$proxy/cargo" +nightly --version | grep '^cargo 1\.100\.0-nightly '

cat > "$project/rust-toolchain.toml" <<'EOF'
[toolchain]
channel = "nightly-2026-09-10"
profile = "minimal"
components = ["rust-src"]
targets = ["wasm32-unknown-unknown"]
EOF

project_version=$(CDPATH= cd -- "$project" && "$proxy/cargo" --version)
case "$project_version" in
  'cargo 1.100.0-nightly '*) ;;
  *) printf '%s\n' "unexpected project Cargo: $project_version" >&2; exit 1 ;;
esac

"$proxy/cargo-stable" --version | grep '^cargo 1\.98\.1 '

HOME="$cache/empty-xdg-home" XDG_CACHE_HOME= \
  "$proxy/cargo" +stable --version | grep '^cargo 1\.98\.1 '
test -d "$cache/empty-xdg-home/.cache/guix-rust-toolchain"

XDG_CACHE_HOME="$cache/nested/cache" \
  "$proxy/cargo" +stable --version | grep '^cargo 1\.98\.1 '
test -d "$cache/nested/cache/guix-rust-toolchain"

if XDG_CACHE_HOME=relative "$proxy/cargo" +stable --version >/dev/null 2>&1; then
  printf '%s\n' "proxy accepted relative XDG_CACHE_HOME" >&2
  exit 1
fi

printf '%s\n' "PASS proxy"
