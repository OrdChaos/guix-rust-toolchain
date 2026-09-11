(use-modules (rust-toolchain manifest) (rust-toolchain database)
             (rust-toolchain component) (guix build utils) (srfi srfi-64))
(test-begin "database")
(define runner (test-runner-current))
(define root (dirname manifests-directory))
(define fixture (read-manifest (string-append root "/tests/fixtures/components.toml")))
(define store-manifests-directory
  (@@ (rust-toolchain database) store-manifests-directory))
(define (resolve . args)
  (resolve-components fixture (apply make-rust-toolchain-spec "stable" args) "future-host"))
(test-equal "unknown future names resolve; gzip fallback" "https://example.org/future.tar.gz"
  (component-url (car (resolve))))
(test-equal "alias stops after one step" "second-alias"
  (component-name (car (resolve #:profile 'empty #:components '("first-alias")))))
(test-error "unavailable fixture" #t (resolve #:components '("unavailable")))
(test-error "no guessed preview suffix" #t (resolve #:components '("future")))
(test-error "store manifest traversal rejected" #t
  (store-manifests-directory "/gnu/store/../../tmp"))
(test-assert "store manifest directory accepted"
  (string-prefix? "/gnu/store/"
    (store-manifests-directory
     (dirname (canonicalize-path
               (search-path %load-path "guix/packages.scm"))))))
(define stable-date (manifest-date (resolve-manifest "stable")))
(define before (getcwd))
(chdir "/tmp")
(test-equal "no working directory dependency" stable-date
  (manifest-date (resolve-manifest "stable")))
(chdir before)
(define temp (mkstemp "/tmp/rust-index-test-XXXXXX"))
(define path (port-filename temp))
(close-port temp)
(for-each
 (lambda (text)
   (call-with-output-file path (lambda (p) (display text p)))
   (test-error "untrusted/malformed index rejected" #t (read-manifest-index path)))
 '("#.(error \"must not evaluate\")" "(system \"false\")" "() ()"
   "((\"stable\" \"../../etc/passwd\" \"bad\"))" "(\"stable\""))
(define marker (string-append path ".executed"))
(call-with-output-file path
  (lambda (p)
    (format p "#.(begin (call-with-output-file ~s (lambda (p) (display \"executed\" p))) '())" marker)))
(test-error "reader evaluation disabled" #t (read-manifest-index path))
(test-assert "reader payload had no side effects" (not (file-exists? marker)))
(delete-file path)
(test-end "database")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
