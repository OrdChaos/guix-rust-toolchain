#!/bin/sh
set -eu

project_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
proxy_package=$(guix build -L "$project_root/guix" \
  -e '(begin (use-modules (rust-toolchain proxy)) %rust-toolchain-proxies)')
cache=$(mktemp -d)
project=$(mktemp -d)
trap 'rm -rf "$cache" "$project"' EXIT HUP INT TERM

proxy="$proxy_package/bin"
export XDG_CACHE_HOME="$cache"

stable_version=$("$proxy/cargo" +stable --version)
nightly_version=$("$proxy/cargo" +nightly --version)
case "$stable_version" in
  'cargo '[0-9]*.*.*' '*) ;;
  *) printf '%s\n' "unexpected stable Cargo: $stable_version" >&2; exit 1 ;;
esac
case "$nightly_version" in
  'cargo '*-nightly' '*) ;;
  *) printf '%s\n' "unexpected nightly Cargo: $nightly_version" >&2; exit 1 ;;
esac
nightly_date=$(
  printf '%s\n' \
    '(use-modules (rust-toolchain manifest) (rust-toolchain database))' \
    '(display (manifest-date (resolve-manifest "nightly")))' \
    | guix repl -L "$project_root/guix" /dev/stdin
)
nightly_channel="nightly-$nightly_date"
test "$("$proxy/cargo" +"$nightly_channel" --version)" = "$nightly_version"
test "$(RUSTUP_TOOLCHAIN=nightly "$proxy/cargo" --version)" = "$nightly_version"
test "$(RUSTUP_TOOLCHAIN=nightly "$proxy/cargo" +stable --version)" = "$stable_version"

for root in "$cache/guix-rust-toolchain/roots/"*; do
  test -L "$root"
  guix gc --list-roots | grep -F -x "$root"
done
for entry in "$cache/guix-rust-toolchain/entries/"????????????????; do
  grep '^provider:/gnu/store/.*-guix-rust-toolchain-provider$' "$entry"
  grep '^guix:/gnu/store/.*-guix-' "$entry"
done

test "$(GUIX_DAEMON_SOCKET=/does-not-exist \
  "$proxy/cargo" +stable --version)" = "$stable_version"

rm -rf "$cache/guix-rust-toolchain"
test "$("$proxy/cargo" +stable --version)" = "$stable_version"

rm -rf "$cache/guix-rust-toolchain"
"$proxy/cargo" +stable --version > "$cache/stable.out" &
stable_pid=$!
"$proxy/cargo" +stable --version > "$cache/stable-second.out" &
stable_second_pid=$!
wait "$stable_pid"
wait "$stable_second_pid"
grep -F -x "$stable_version" "$cache/stable.out"
grep -F -x "$stable_version" "$cache/stable-second.out"

stable_entry=$(grep -l '^channel:stable$' \
  "$cache/guix-rust-toolchain/entries/"????????????????)
stable_name=$(basename "$stable_entry")
stable_root=$(readlink "$cache/guix-rust-toolchain/roots/$stable_name")
test "$(RUSTUP_TOOLCHAIN="$stable_root" "$proxy/cargo" --version)" = "$stable_version"
printf '%s\n' corrupt > "$stable_entry"
test "$("$proxy/cargo" +stable --version)" = "$stable_version"
rm "$cache/guix-rust-toolchain/roots/$stable_name"
test "$("$proxy/cargo" +stable --version)" = "$stable_version"

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

test "$("$proxy/cargo" +nightly --version)" = "$nightly_version"

cat > "$project/rust-toolchain.toml" <<EOF
[toolchain]
channel = "$nightly_channel"
profile = "minimal"
components = ["rust-src"]
targets = ["wasm32-unknown-unknown"]
EOF
mkdir -p "$project/src"
printf '%s\n' 'pub fn answer() -> u32 { 42 }' > "$project/src/lib.rs"

project_version=$(CDPATH='' cd -- "$project" && "$proxy/cargo" --version)
test "$project_version" = "$nightly_version"
project_analyzer_version=$(CDPATH='' cd -- "$project" && "$proxy/rust-analyzer" --version)
case "$project_analyzer_version" in
  'rust-analyzer '*) ;;
  *) printf '%s\n' "unexpected Rust analyzer: $project_analyzer_version" >&2; exit 1 ;;
esac
(CDPATH='' cd -- "$project" && "$proxy/rust-analyzer" analysis-stats . >/dev/null)

test "$("$proxy/cargo-stable" --version)" = "$stable_version"
test "$("$proxy/rust-analyzer-stable" --version)" = "$("$proxy/rust-analyzer" +stable --version)"

HOME="$cache/empty-xdg-home" XDG_CACHE_HOME='' \
  "$proxy/cargo" +stable --version | grep -F -x "$stable_version"
test -d "$cache/empty-xdg-home/.cache/guix-rust-toolchain"

XDG_CACHE_HOME="$cache/nested/cache" \
  "$proxy/cargo" +stable --version | grep -F -x "$stable_version"
test -d "$cache/nested/cache/guix-rust-toolchain"

if XDG_CACHE_HOME=relative "$proxy/cargo" +stable --version >/dev/null 2>&1; then
  printf '%s\n' "proxy accepted relative XDG_CACHE_HOME" >&2
  exit 1
fi

printf '%s\n' "PASS proxy"
