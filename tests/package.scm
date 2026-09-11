(use-modules (rust-toolchain package) (guix packages) (guix store)
             (guix derivations) (srfi srfi-64))
(test-begin "package")
(define runner (test-runner-current))
(test-assert "normal package" (package? %rust-stable))
(test-equal "pinned stable" "1.98.1" (package-version %rust-stable))
(test-equal "pinned nightly" "nightly-2026-09-10" (package-version %rust-nightly))
(test-equal "stable package name" "rust-toolchain-stable"
  (package-name %rust-stable))
(test-equal "nightly package name" "rust-toolchain-nightly"
  (package-name %rust-nightly))
(test-equal "host-qualified channel" "1.98.1"
  (package-version (rust-toolchain "1.98.1-x86_64-unknown-linux-gnu")))
(test-equal "single output" '("out") (package-outputs %rust-stable))
(test-error "unsupported host" #t (rust-toolchain "stable" #:system "aarch64-linux"))
(test-assert "open cross targets"
  (package? (rust-toolchain "stable" #:profile 'minimal
             #:components '("rust-src" "llvm-tools")
             #:targets '("wasm32-unknown-unknown" "aarch64-unknown-linux-gnu"))))
(with-store store
  (test-assert "lower stable package with fixed origins"
    (derivation? (package-derivation store
                  (rust-toolchain "1.98.1" #:profile 'minimal
                    #:components '("rust-src" "llvm-tools"))))))
(test-end "package")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
