# guix-rust-toolchain

`guix-rust-toolchain` packages official Rust binary distributions as immutable
Guix store items.  It provides stable, beta, and nightly toolchains, arbitrary
manifest components and targets, and rustup-style command proxies without
rustup, mutable toolchain state, or runtime downloads.

Bundled channel aliases follow checksum-pinned snapshots in
`manifests/index.scm`.  Exact releases and dated nightlies remain available
after an alias advances.  The host platform is currently `x86_64-linux`.

## Use The Proxy

Construct a proxy from declared toolchain entries:

```scheme
(use-modules (rust-toolchain proxy))

(define %toolchains
  (list (rust-toolchain-entry "stable"
                              #:components '("rust-analyzer-preview" "rust-src"))
        (rust-toolchain-entry "nightly"
                              #:components '("rust-analyzer-preview" "rust-src"))))

(rust-toolchain-proxies #:toolchains %toolchains
                         #:default-stable "stable"
                         #:default-nightly "nightly")
```

The installed `cargo`, `rustc`, `rustdoc`, and `rust-analyzer` commands execute
only a declared store path.  Selection precedence follows rustup where it is
stateless: `+selector`, `RUSTUP_TOOLCHAIN`, nearest project toolchain file, then
the stable default.

```sh
cargo +stable --version
rustc +nightly --version
```

Legacy one-line `rust-toolchain` files and a minimal TOML file are supported:

```toml
[toolchain]
channel = "nightly"
```

`stable`, `beta`, and `nightly` resolve to declared defaults.  An explicit
selector must name a declared entry.  `rust-analyzer` requires its selected
package to include `rust-analyzer-preview` and `rust-src`.  Other TOML fields
fail rather than causing an implicit package variant.

The proxy never invokes Guix or downloads a toolchain.  An undeclared selector
fails with a generic hint to install or enter an environment containing a
matching `rust-toolchain` package.  Direct packages remain usable independently,
including through `guix shell -e`.

## Package API

Scheme callers can construct a package directly:

```scheme
(use-modules (rust-toolchain package))

(rust-toolchain "stable"
  #:profile 'minimal
  #:components '("rust-src" "clippy" "rustfmt")
  #:targets '("wasm32-unknown-unknown" "aarch64-unknown-linux-gnu"))
```

The module also exports `%rust-stable` and `%rust-nightly`.  Explicit unavailable
components or targets are errors rather than silently omitted.

This repository is a Guix channel with package modules under `guix/`.  Add its
Git URL to a channel declaration in the usual way; `.guix-channel` sets the
module directory automatically.  See `PUBLISHING.md` for GitHub publication,
channel authentication, and the automated update workflow.

## Update Manifests

Normal evaluation is offline and reads only bundled, checksum-verified official
Rust dist v2 manifests.  Network access is isolated in the maintainer command:

```sh
guix repl -L guix scripts/update-manifests.scm stable beta nightly
```

Accepted selectors are `stable`, `beta`, `nightly`, `nightly-YYYY-MM-DD`, and
exact Rust release selectors.  The updater checks the official `.sha256`,
validates the snapshot, and atomically updates the index.  It does not run Git
or create commits.  See `ARCHITECTURE.md` for the data model and trust boundary.

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

The live updater test is intentionally separate because it contacts the
official Rust distribution server:

```sh
./scripts/validate-release.sh --live
```

GitHub Actions run release validation for pushes and pull requests.  A daily
workflow updates official channel manifests and publishes authenticated commits.

## License

Provider and proxy source code is available under GPL-3.0-or-later.  The
packaged Rust artifacts retain their upstream Apache-2.0 and MIT licenses.
