(use-modules (rust-toolchain proxy) (guix derivations) (guix packages)
             (guix store) (srfi srfi-64))
(test-begin "proxy")
(define runner (test-runner-current))
(test-assert "proxy package" (package? %rust-toolchain-proxies))
(define stable-entry (rust-toolchain-entry "stable"))
(define nightly-entry (rust-toolchain-entry "nightly"))
(define %configured-proxies
  (rust-toolchain-proxies #:toolchains (list stable-entry nightly-entry)
                           #:default-stable "stable"
                           #:default-nightly "nightly"))
(test-assert "configured proxy package" (package? %configured-proxies))
(test-assert "entry owns a package" (package? (rust-toolchain-entry-package stable-entry)))
(test-equal "entry records default profile" "default"
  (rust-toolchain-entry-profile stable-entry))
(test-equal "entry records components" '()
  (rust-toolchain-entry-components stable-entry))
(test-equal "entry records targets" '()
  (rust-toolchain-entry-targets stable-entry))
(test-error "reject invalid static profile" #t
  (rust-toolchain-entry "stable" #:profile 'tiny))
(test-error "reject registry delimiter in component" #t
  (rust-toolchain-entry "stable" #:components '("rust-src,other")))
(test-error "reject non-string stable default" #t
  (rust-toolchain-proxies #:toolchains (list stable-entry)
                           #:default-stable 1))
(test-error "reject undeclared nightly default" #t
  (rust-toolchain-proxies #:toolchains (list nightly-entry)
                           #:default-stable "stable"))
(with-store store
  (test-assert "proxy package lowers"
    (derivation? (package-derivation store %configured-proxies))))
(test-end "proxy")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
