#!/bin/sh
set -eu

if [ "${CI-}" = true ]; then
  set -x
fi

project_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
proxy_package=$(guix build -L "$project_root/guix" \
  -e '(begin
         (use-modules (rust-toolchain proxy))
         (rust-toolchain-proxies
          #:toolchains
          (list (rust-toolchain-entry "stable"
                                      #:components (list "rust-analyzer-preview" "rust-src"))
                (rust-toolchain-entry "nightly"
                                      #:components (list "rust-analyzer-preview" "rust-src")))
          #:default-stable "stable"
          #:default-nightly "nightly"))')
work=$(mktemp -d)
project="$work/project"
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir "$project"

proxy="$proxy_package/bin"
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

test "$(RUSTUP_TOOLCHAIN=nightly "$proxy/cargo" --version)" = "$nightly_version"
test "$(RUSTUP_TOOLCHAIN=nightly "$proxy/cargo" +stable --version)" = "$stable_version"
test "$(GUIX_DAEMON_SOCKET=/does-not-exist "$proxy/cargo" +stable --version)" \
  = "$stable_version"

if "$proxy/cargo" +not-declared --version >"$work/missing.out" 2>&1; then
  printf '%s\n' "proxy accepted an undeclared selector" >&2
  exit 1
fi
grep -F -x "hint: install or enter an environment containing a matching rust-toolchain package" \
  "$work/missing.out"

cat > "$project/rust-toolchain.toml" <<'EOF'
[toolchain]
channel = "nightly"
EOF

project_version=$(CDPATH='' cd -- "$project" && "$proxy/cargo" --version)
test "$project_version" = "$nightly_version"
project_analyzer_version=$(CDPATH='' cd -- "$project" && "$proxy/rust-analyzer" --version)
case "$project_analyzer_version" in
  'rust-analyzer '*) ;;
  *) printf '%s\n' "unexpected Rust analyzer: $project_analyzer_version" >&2; exit 1 ;;
esac

XDG_CACHE_HOME="$work/cache" "$proxy/cargo" +stable --version | grep -F -x "$stable_version"
test ! -e "$work/cache/guix-rust-toolchain"

printf '%s\n' "PASS proxy"
