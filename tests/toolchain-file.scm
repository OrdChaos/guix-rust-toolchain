(use-modules (rust-toolchain component)
             (rust-toolchain toolchain-file)
             (guix build utils)
             (guix packages)
             (srfi srfi-64))

(test-begin "toolchain-file")
(define runner (test-runner-current))
(define temporary (mkstemp "/tmp/rust-toolchain-file-XXXXXX"))
(define root (port-filename temporary))
(close-port temporary)
(delete-file root)
(mkdir root)
(define child (string-append root "/a/b"))
(mkdir-p child)

(define (write path text)
  (call-with-output-file path (lambda (port) (display text port))))

(define legacy (string-append root "/rust-toolchain"))
(write legacy "nightly-2026-09-10\n")
(define spec (rust-toolchain-spec-from-file legacy))
(test-equal "legacy channel" "nightly-2026-09-10"
  (rust-toolchain-spec-channel spec))
(test-equal "parent search" legacy (find-rust-toolchain-file child))

(define toml (string-append root "/rust-toolchain.toml"))
(write toml "[toolchain]\nchannel = \"1.98.1\"\nprofile = \"minimal\"\ncomponents = [\"rust-src\", \"llvm-tools\"]\ntargets = [\"wasm32-unknown-unknown\"]\n")
(test-equal "legacy wins in same directory" legacy
  (find-rust-toolchain-file child))
(delete-file legacy)
(define parsed (rust-toolchain-spec-from-file toml))
(test-equal "TOML channel" "1.98.1" (rust-toolchain-spec-channel parsed))
(test-equal "TOML profile" 'minimal (rust-toolchain-spec-profile parsed))
(test-equal "TOML components" '("rust-src" "llvm-tools")
  (rust-toolchain-spec-components parsed))
(test-equal "TOML targets" '("wasm32-unknown-unknown")
  (rust-toolchain-spec-targets parsed))
(test-assert "file API returns package" (package? (rust-toolchain-from-file toml)))
(test-assert "current-directory API returns package"
  (package? (rust-toolchain-from-current-directory child)))

(for-each
 (lambda (text)
   (write toml text)
   (test-error "malformed or unsupported" #t
     (rust-toolchain-spec-from-file toml)))
 '("[toolchain]\nchannel = \"stable\"\npath = \"/tmp/rust\"\n"
   "[toolchain]\nchannel = \"stable\"\nprofile = \"tiny\"\n"
   "[toolchain]\nchannel = \"stable\"\ncomponents = \"rust-src\"\n"
   "[toolchain]\nprofile = \"minimal\"\n"
   "channel = \"stable\"\n"
   "not valid TOML"))

(delete-file-recursively root)
(test-end "toolchain-file")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
