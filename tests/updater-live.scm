;; Explicit opt-in network integration test; ordinary test suites are offline.
(use-modules (rust-toolchain database) (rust-toolchain manifest)
             (guix utils) (srfi srfi-64))
(primitive-load (string-append (dirname manifests-directory) "/scripts/update-manifests.scm"))
(test-begin "updater-live")
(define runner (test-runner-current))
(call-with-temporary-directory
 (lambda (directory)
   (update-manifests '("stable" "beta" "nightly" "1.98.1" "nightly-2026-09-10")
                     #:directory directory)
   (for-each (lambda (channel)
               (test-assert "official snapshot verifies and resolves"
                 (manifest? (resolve-manifest channel #:directory directory))))
             '("stable" "beta" "nightly" "1.98.1" "nightly-2026-09-10"))
   (test-assert "beta version"
     (string-contains (manifest-version (resolve-manifest "beta" #:directory directory)) "-beta"))))
(test-end "updater-live")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
