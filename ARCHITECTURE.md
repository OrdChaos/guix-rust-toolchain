# Rust Toolchain Manifest Provider

The provider reads bundled, byte-for-byte official Rust dist v2 TOML. Evaluation
has no network access and consults no rustup state. A toolchain resolves from one
coherent snapshot, never from independently moving component versions.

Guix's `(guix build toml)` explicitly lacks arrays-of-tables support; official
manifests use those for host components/extensions. Our strict recursive-descent
subset supports bare/quoted keys, dotted table headers, leaf arrays of tables,
single-line basic/literal strings (including escapes), booleans and arrays.
It rejects dotted assignments, inline tables, numeric/date values, multiline strings, nested
array-table paths, duplicate keys/tables and trailing garbage rather than silently
losing data. Raw data is a string-keyed alist; arrays are lists in source order.
Names are open strings, not a maintained component or target enumeration.

`database.scm` normally locates `manifests/` relative to its provider module,
not the process working directory. The store-built proxy supplies its bundled
manifest location through an internal override restricted to `/gnu/store`.
The index is one validated Scheme datum, read with reader evaluation disabled,
never loaded/evaluated as code. Digest-derived paths prevent traversal;
resolution checks snapshot bytes against the index hash.

Profiles expand the manifest's `[profiles]` entries filtered against the host's
`pkg.rust.target.HOST.components` and `extensions`. Thus `rust-mingw` is omitted
on Linux, but an explicit request for it fails. Renames follow exactly one
`[renames.NAME].to` edge. Source components use target `*`; extra targets request
`rust-std`. Applicable but unavailable packages fail explicitly. URLs and matching
hex hashes prefer xz, falling back to gzip only if xz is absent. Results are
deduplicated by (component, target), preserving request order.

## Updating

Run `guix repl -L guix scripts/update-manifests.scm CHANNEL ...` from the project.
Supported inputs are `stable`, `beta`, `nightly`, `nightly-YYYY-MM-DD`, and full
`MAJOR.MINOR.PATCH` versions. The default bundled aliases are stable/1.98.1 and
nightly/nightly-2026-09-10; beta is supported by the updater but not prebundled.
Use absolute `-L` and script paths when invoking from another directory.

Only this explicit maintainer script accesses the network. It requires `curl`
on PATH and forces HTTPS for initial requests and redirects. It downloads raw
TOML and the corresponding official `.sha256` into a temporary directory,
validates the entire digest and checksum filename, parses/schema-checks every
manifest, and verifies requested version/date identities before publishing any
member of the batch. This is checksum integrity over authenticated HTTPS, not
an independent signature/authenticity guarantee.

A publication lock serializes writers. Snapshot paths contain their complete
SHA-256 and are linked into place without overwriting existing paths. Exact
version/date index entries cannot be rebound; moving aliases can. Updating
stable also pins its exact version; updating nightly also pins its date.
All alias changes are one validated, fsynced temporary index renamed atomically.
Readers see either the old or new complete index. A crash before index replacement
may leave unreferenced immutable snapshots; directory entries are not fsynced,
so this is atomic visibility, not a power-loss durability guarantee. The updater
prints old/new hashes, package/target diff summaries and exact index changes,
and never runs Git or commits. Publication failure can leave orphan snapshots
but never a partially written index. Do not modify snapshots manually.

## API

- `(rust-toolchain manifest)`: `read-manifest`, `manifest?`, `manifest-date`,
  `manifest-version`, `manifest-data`; helpers `manifest-ref`, `sha256-hex?`,
  `iso-date?`. `manifest-ref` takes a raw alist and string path keys.
- `(rust-toolchain component)`: `make-rust-toolchain-spec` with channel string
  and `#:profile`, `#:components`, `#:targets`; the four agreed spec accessors
  and `rust-toolchain-spec?`; `resolve-components`; `component?` and the agreed
  name/target/url/sha256/available? accessors. Names/targets are strings; profile
  accepts a symbol or string. SHA-256 values are lowercase hex strings.
- `(rust-toolchain database)`: `resolve-manifest`; additionally
  `read-manifest-index`, `manifests-directory`, `file-sha256`, `channel?`, and
  `channel-manifest-url`. Resolution accepts optional `#:directory` for tests or
  alternate explicitly selected databases, never network fallback.
- `(rust-toolchain package)`: `rust-toolchain` constructs one immutable package
  from a channel, profile, component list, and target list; `%rust-stable` and
  `%rust-nightly` are the bundled defaults. The current host is x86_64-linux.
- `(rust-toolchain toolchain-file)`: parses legacy and TOML project files, finds
  them through parent directories, and lowers their complete request to a
  package.
- `(rust-toolchain proxy)`: `%rust-toolchain-proxies` provides rustup-style
  command names. The C fast path validates request-keyed cache entries and Guix
  indirect roots before directly executing the selected store binary.
- `(rust-toolchain toml)`: `read-rust-toml` takes an input port.
- The updater script defines `update-manifests` (channel list, optional
  `#:directory` and injected `#:fetch` for tests), `fetch-official`, and
  `read-official-checksum`. It is not an evaluation-time provider module.

## Verification

Run each offline suite with Guix, not plain Guile:

```sh
guix repl -L guix tests/manifest.scm
guix repl -L guix tests/components.scm
guix repl -L guix tests/database.scm
guix repl -L guix tests/updater.scm
guix repl -L guix tests/package.scm
guix repl -L guix tests/toolchain-file.scm
guix repl -L guix tests/proxy.scm
```

Explicit network integration (temporary database only):
`guix repl -L guix tests/updater-live.scm`.

Native, cross, and proxy integration checks are respectively
`guix repl -L guix scripts/validate-toolchains.scm`,
`guix repl -L guix scripts/validate-cross.scm`, and
`./scripts/validate-proxy.sh`.

The parser is intentionally not full TOML. Future official syntax outside the
documented subset requires an explicit parser extension with a real-manifest
regression. Package construction downloads only the fixed component origins
selected from this metadata, then installs and patches them inside the Guix
build sandbox. Resolution returns only available components; unavailable
requests throw instead of returning a record with `component-available?` false.
