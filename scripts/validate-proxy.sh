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

for root in "$cache/guix-rust-toolchain/roots/"*; do
  test -L "$root"
  guix gc --list-roots | grep -F -x "$root"
done

GUIX_DAEMON_SOCKET=/does-not-exist "$proxy/cargo" +stable --version \
  | grep '^cargo 1\.98\.1 '

rm -rf "$cache/guix-rust-toolchain"
"$proxy/cargo" +stable --version | grep '^cargo 1\.98\.1 '

rm -rf "$cache/guix-rust-toolchain"
"$proxy/cargo" +stable --version > "$cache/stable.out" &
stable_pid=$!
"$proxy/cargo" +nightly --version > "$cache/nightly.out" &
nightly_pid=$!
wait "$stable_pid"
wait "$nightly_pid"
grep '^cargo 1\.98\.1 ' "$cache/stable.out"
grep '^cargo 1\.100\.0-nightly ' "$cache/nightly.out"

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
printf '%s\n' "PASS proxy"
