#!/bin/sh
set -eu

project_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
test_work=$(mktemp -d "${TMPDIR:-/tmp}/guix-rust-toolchain-tests.XXXXXX")
trap 'rm -rf "$test_work"' EXIT HUP INT TERM
live=false
case "${1-}" in
  "") ;;
  --live) live=true ;;
  *) printf '%s\n' "usage: $0 [--live]" >&2; exit 2 ;;
esac

for test in manifest components database updater package toolchain-file proxy; do
  (cd "$test_work" &&
    guix repl -L "$project_root/guix" "$project_root/tests/$test.scm")
done

guix repl -L "$project_root/guix" \
  "$project_root/scripts/validate-toolchains.scm"
guix repl -L "$project_root/guix" "$project_root/scripts/validate-cross.scm"
"$project_root/scripts/validate-proxy.sh"

if $live; then
  guix repl -L "$project_root/guix" "$project_root/tests/updater-live.scm"
fi

printf '%s\n' "PASS release validation"
