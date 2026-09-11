# guix-rust-toolchain

`guix-rust-toolchain` packages official Rust binary distributions as immutable,
garbage-collector-aware Guix store items. It provides pinned stable and nightly
toolchains, arbitrary manifest components and targets, standard
`rust-toolchain.toml` selection, and rustup-style command proxies without using
rustup or mutable toolchain installation state.

The bundled snapshots currently provide Rust 1.98.1 and
nightly-2026-09-10. The host platform is currently limited to
`x86_64-linux`; target standard libraries remain an open string set governed by
the selected official manifest.

## Use The Proxy

Install the proxy package from a checkout:

```sh
guix install -L guix rust-toolchain-proxies
```

The installed `cargo`, `rustc`, and `rustdoc` commands select stable by default,
or the nearest project toolchain file:

```toml
[toolchain]
channel = "nightly-2026-09-10"
profile = "minimal"
components = ["rust-src", "clippy", "rustfmt"]
targets = ["wasm32-unknown-unknown"]
```

Legacy one-line `rust-toolchain` files are also supported. An explicit
`+stable`, `+nightly`, or `+nightly-YYYY-MM-DD` argument takes precedence over
`RUSTUP_TOOLCHAIN` and project files, and is removed before the real command
runs. Host-qualified forms such as `stable-x86_64-unknown-linux-gnu` are
accepted for the supported host.

```sh
cargo +stable --version
rustc +nightly-2026-09-10 --version
```

The suffixed commands `cargo-stable`, `rustc-stable`, `rustdoc-stable`,
`cargo-nightly`, `rustc-nightly`, and `rustdoc-nightly` provide the same fixed
selection without a `+` argument.

The first use realizes the selected package through Guix. Subsequent uses read
a small cache under `${XDG_CACHE_HOME:-$HOME/.cache}/guix-rust-toolchain` and
execute the store binary directly. Cache entries are validated against their
complete request and store target. Guix indirect roots keep selected toolchains
alive. Previous requests remain rooted until the cache is removed; run
`rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/guix-rust-toolchain"` to retire them.
Deleting the cache only causes active toolchains to be realized again on use.

## Package API

Scheme callers can construct a package directly:

```scheme
(use-modules (rust-toolchain package))

(rust-toolchain "1.98.1"
  #:profile 'minimal
  #:components '("rust-src" "clippy" "rustfmt")
  #:targets '("wasm32-unknown-unknown" "aarch64-unknown-linux-gnu"))
```

The module also exports `%rust-stable` and `%rust-nightly`. From a checkout,
`guix install -L guix rust-toolchain-stable` and
`guix install -L guix rust-toolchain-nightly` install those packages directly.
Explicit unavailable components or targets are errors rather than silently
omitted.

This repository is a Guix channel with package modules under `guix/`. Add its
Git URL to a channel declaration in the usual way; `.guix-channel` sets the
module directory automatically.

## Update Manifests

Normal evaluation is offline and reads only bundled, checksum-verified official
Rust dist v2 manifests. Network access is isolated in the maintainer command:

```sh
guix repl -L guix scripts/update-manifests.scm stable nightly
```

Accepted selectors are `stable`, `beta`, `nightly`,
`nightly-YYYY-MM-DD`, and exact `MAJOR.MINOR.PATCH` versions. The updater checks
the official `.sha256`, validates the snapshot, and atomically updates the
index. It does not run Git or create commits. See `ARCHITECTURE.md` for the data
model and trust boundary.

## Verify

Run the offline unit suites:

```sh
for test in manifest components database updater package toolchain-file proxy; do
  guix repl -L guix "tests/$test.scm"
done
```

Run build and runtime integration checks:

```sh
guix repl -L guix scripts/validate-toolchains.scm
guix repl -L guix scripts/validate-cross.scm
./scripts/validate-proxy.sh
```

Run all of the above through one release entry point:

```sh
./scripts/validate-release.sh
```

The live updater test is intentionally separate because it contacts the official
Rust distribution server:

```sh
./scripts/validate-release.sh --live
```

## License

Provider and proxy source code is available under GPL-3.0-or-later. The packaged
Rust artifacts retain their upstream Apache-2.0 and MIT licenses.
