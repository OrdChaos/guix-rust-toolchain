(use-modules (rust-toolchain manifest) (rust-toolchain database)
             (rust-toolchain component) (srfi srfi-1) (srfi srfi-64))
(test-begin "components")
(define runner (test-runner-current))
(define stable (resolve-manifest "stable"))
(define nightly (resolve-manifest "nightly-2026-09-10"))
(define host "x86_64-unknown-linux-gnu")
(define (components manifest . options)
  (resolve-components manifest (apply make-rust-toolchain-spec "stable" options) host))
(test-equal "minimal Linux filters mingw" '("rustc" "cargo" "rust-std")
  (map component-name (components stable #:profile 'minimal)))
(test-equal "default Linux" '("rustc" "cargo" "rust-std" "rust-docs" "rustfmt-preview" "clippy-preview")
  (map component-name (components stable)))
(test-equal "one-step alias and dedup" 1
  (count (lambda (c) (string=? (component-name c) "clippy-preview"))
         (components stable #:components '("clippy" "clippy-preview"))))
(test-equal "source wildcard" "*"
  (component-target (last (components stable #:components '("rust-src")))))
(test-assert "prefer xz with hex hash"
  (every (lambda (c) (and (string-suffix? ".tar.xz" (component-url c))
                          (sha256-hex? (component-sha256 c)) (component-available? c)))
         (components stable)))
(for-each (lambda (target)
            (test-equal "open target" target
              (component-target (last (components nightly #:targets (list target))))))
          '("wasm32-wasip3" "x86_64-unknown-linux-gnumsan" "x86_64-unknown-linux-gnutsan"))
(test-assert "enzyme name parsed dynamically"
  (manifest-ref (manifest-data nightly) "pkg" "enzyme-preview"))
(test-assert "offload name parsed dynamically"
  (manifest-ref (manifest-data nightly) "pkg" "offload-preview"))
(for-each (lambda (name)
            (test-equal "new component resolves on real nightly" name
              (component-name (last (components nightly #:components (list name))))))
          '("enzyme-preview" "offload-preview"))
(test-equal "real enzyme alias" "enzyme-preview"
  (component-name (last (components nightly #:components '("enzyme")))))
(for-each (lambda (options)
            (test-error "absent/unavailable explicit request" #t
              (apply components stable options)))
          (list (list #:components '("no-such-component"))
                (list #:components '("rust-mingw"))
                (list #:components '("miri"))
                (list #:targets '("no-such-target"))
                (list #:profile 'no-such-profile)))
(test-error "unknown host" #t
  (resolve-components stable (make-rust-toolchain-spec "stable") "no-such-host"))
(test-error "absent beta alias" #t (resolve-manifest "beta"))
(test-error "path traversal channel" #t (resolve-manifest "../../etc/passwd"))
(test-assert "beta updater endpoint"
  (string-suffix? "/channel-rust-beta.toml" (channel-manifest-url "beta")))
(test-end "components")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
