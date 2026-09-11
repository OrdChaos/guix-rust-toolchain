# Package Validation

Run `scripts/validate-toolchains.scm` for native checks and
`scripts/validate-cross.scm` for cross checks. Both construct test derivations,
so compilation happens in the Guix daemon sandbox rather than in the caller's
distribution environment.

Validated on 2026-09-10 with the current Guix installation:

- Rust 1.98.1: rustc, Cargo, rustdoc, rustfmt, Clippy, LLVM tools, rust-src,
  direct rustc hello world, and Cargo hello world passed.
- nightly-2026-09-10: the same native checks passed; rustc reported
  `1.100.0-nightly (a36d05efa 2026-09-09)`.
- ELF inspection showed the packaged tools use a `/gnu/store` glibc
  interpreter and store-only RUNPATH entries.

Exact store paths are intentionally not treated as stable test data. The
scripts print their realized derivations and outputs for each run.
