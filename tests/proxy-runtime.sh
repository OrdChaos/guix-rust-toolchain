#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir "$work/stable" "$work/nightly" "$work/project"

for name in cargo rustc rustdoc rust-analyzer; do
  for toolchain in stable nightly; do
    cat > "$work/$toolchain/$name" <<EOF
#!/bin/sh
printf '%s\\n' '$toolchain'
EOF
    chmod +x "$work/$toolchain/$name"
  done
done

registry="$work/registry"
printf 'stable\t%s\tdefault\trust-src\twasm32-unknown-unknown\n' "$work/stable" > "$registry"
printf 'nightly-2026-08-01\t%s\tdefault\trust-src\twasm32-unknown-unknown\n' "$work/nightly" >> "$registry"
gcc -std=c11 -O2 -Wall -Wextra -Werror "-DREGISTRY=\"$registry\"" \
  "$root/src/proxy.c" -o "$work/proxy"
ln -s proxy "$work/cargo"

cat > "$work/project/rust-toolchain.toml" <<'EOF'
[toolchain]
channel = "nightly-2026-08-01"
components = [
    "rust-src"
]
EOF

test "$(CDPATH='' cd -- "$work/project" && "$work/cargo")" = nightly
test "$(CDPATH='' cd -- "$work/project" && "$work/cargo" +stable)" = stable
test "$(CDPATH='' cd -- "$work/project" && RUSTUP_TOOLCHAIN=stable "$work/cargo")" = stable

cat > "$work/project/rust-toolchain.toml" <<'EOF'
[toolchain]
channel = "nightly-2026-08-01"
targets = ["wasm32-unknown-unknown"]
EOF
test "$(CDPATH='' cd -- "$work/project" && "$work/cargo")" = nightly

cat > "$work/project/rust-toolchain.toml" <<'EOF'
[toolchain]
channel = "nightly-2026-08-01"
components = ["rustfmt"]
EOF
if (CDPATH='' cd -- "$work/project" && "$work/cargo") >"$work/error" 2>&1; then
  printf '%s\n' "proxy accepted an undeclared component" >&2
  exit 1
fi
grep -F -x "hint: install or enter an environment containing a matching rust-toolchain package" \
  "$work/error"

cat > "$work/project/rust-toolchain.toml" <<'EOF'
[toolchain]
channel="nightly-2026-08-01"
profile="minimal"
EOF
if (CDPATH='' cd -- "$work/project" && "$work/cargo") >"$work/error" 2>&1; then
  printf '%s\n' "proxy accepted an undeclared profile" >&2
  exit 1
fi
grep -F -x "hint: install or enter an environment containing a matching rust-toolchain package" \
  "$work/error"

cat > "$work/project/rust-toolchain.toml" <<'EOF'
[toolchain]
channel="nightly-2026-08-01"
targets=["aarch64-unknown-linux-gnu"]
EOF
if (CDPATH='' cd -- "$work/project" && "$work/cargo") >"$work/error" 2>&1; then
  printf '%s\n' "proxy accepted an undeclared target" >&2
  exit 1
fi
grep -F -x "hint: install or enter an environment containing a matching rust-toolchain package" \
  "$work/error"

rm "$work/project/rust-toolchain.toml"
printf '%s\n' "nightly-2026-08-01" > "$work/project/rust-toolchain"
test "$(CDPATH='' cd -- "$work/project" && "$work/cargo")" = nightly

printf '%s\n' "PASS proxy runtime"
