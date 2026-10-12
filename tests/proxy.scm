(use-modules (rust-toolchain proxy) (guix derivations) (guix packages)
             (guix store) (srfi srfi-64))
(test-begin "proxy")
(define runner (test-runner-current))
(test-assert "proxy package" (package? %rust-toolchain-proxies))
(define %configured-proxies
  (rust-toolchain-proxies #:default-stable "1.99.0"
                          #:default-nightly "nightly-2026-10-10"))
(test-assert "configured proxy package" (package? %configured-proxies))
(test-error "reject malformed stable default" #t
  (rust-toolchain-proxies #:default-stable "stable"))
(test-error "reject malformed nightly default" #t
  (rust-toolchain-proxies #:default-nightly "nightly"))
(with-store store
  (test-assert "proxy package lowers"
    (derivation? (package-derivation store %rust-toolchain-proxies))))
(test-end "proxy")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
