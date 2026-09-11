(use-modules (rust-toolchain proxy) (guix derivations) (guix packages)
             (guix store) (srfi srfi-64))
(test-begin "proxy")
(define runner (test-runner-current))
(test-assert "proxy package" (package? %rust-toolchain-proxies))
(with-store store
  (test-assert "proxy package lowers"
    (derivation? (package-derivation store %rust-toolchain-proxies))))
(test-end "proxy")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
