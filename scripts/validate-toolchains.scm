;;; Run: guix repl -L guix scripts/validate-toolchains.scm [CHANNEL ...]
;;; Native smoke tests run in a daemon build, not the caller's distro environment.
(use-modules (rust-toolchain package) (guix packages) (guix store)
             (guix derivations) (guix gexp) (guix build-system trivial)
             (gnu packages base) (srfi srfi-1))

(define (validate channel)
  (let* ((toolchain (rust-toolchain channel #:profile 'minimal
                      #:components '("rust-src" "llvm-tools" "clippy" "rustfmt")))
         (check
          (package
            (inherit toolchain)
            (name "rust-toolchain-native-check")
            (arguments
             (list
              #:builder
              (with-imported-modules '((guix build utils))
              #~(begin
                  (use-modules (guix build utils) (ice-9 popen)
                               (ice-9 textual-ports) (srfi srfi-13))
                  (define (output . arguments)
                    (let* ((port (apply open-pipe* OPEN_READ arguments))
                           (text (get-string-all port))
                           (status (close-pipe port)))
                      (unless (zero? status) (error "inspection failed" arguments))
                      text))
                  (define (validate-elf file)
                    (let ((program (output #$(file-append binutils "/bin/readelf")
                                           "-l" file))
                          (dynamic (output #$(file-append binutils "/bin/readelf")
                                           "-d" file)))
                      (unless (string-contains program
                                               "Requesting program interpreter: /gnu/store/")
                        (error "non-store ELF interpreter" file program))
                      (when (string-contains dynamic "/usr/")
                        (error "impure ELF dynamic path" file dynamic))))
                  (setenv "PATH" #$(file-append toolchain "/bin"))
                  (setenv "HOME" (getcwd))
                  (setenv "CARGO_HOME" (string-append (getcwd) "/cargo-home"))
                  (for-each unsetenv '("LIBRARY_PATH" "LD_LIBRARY_PATH" "CC" "RUSTFLAGS"))
                  (for-each (lambda (tool) (invoke tool "--version"))
                            '("rustc" "cargo" "rustdoc" "rustfmt" "clippy-driver"))
                  (invoke "rustc" "--version" "--verbose")
                  (call-with-output-file "hello.rs"
                    (lambda (p) (display "fn main() { println!(\"hello-guix\"); }\n" p)))
                  (invoke "rustc" "hello.rs" "-o" "hello")
                  (invoke "./hello")
                  (validate-elf "hello")
                  (invoke "rustdoc" "hello.rs")
                  (invoke "cargo" "new" "--vcs" "none" "cargo-hello")
                  (with-directory-excursion "cargo-hello"
                    (invoke "cargo" "run" "--offline")
                    (validate-elf "target/debug/cargo-hello")
                    (invoke "cargo" "clippy" "--offline" "--" "-D" "warnings")
                    (invoke "cargo" "fmt" "--check"))
                  (invoke #$(file-append toolchain "/lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-objdump")
                          "--version")
                  (unless (file-exists? #$(file-append toolchain "/lib/rustlib/src/rust/library/core/src/lib.rs"))
                    (error "missing rust-src"))
                  (mkdir #$output)
                  (copy-file "hello" (string-append #$output "/hello")))))))))
    (with-store store
      (let ((drv (package-derivation store toolchain)))
        (format #t "BUILD ~a ~a\n" channel (derivation-file-name drv))
        (force-output)
        (build-derivations store (list drv))
        (format #t "TOOLCHAIN ~a ~a\n" channel (derivation->output-path drv)))
      (let ((drv (package-derivation store check)))
        (build-derivations store (list drv))
        (format #t "PASS native ~a ~a\n" channel (derivation->output-path drv))))))

(define channels (if (null? (cdr (command-line)))
                     '("1.98.1" "nightly-2026-09-10") (cdr (command-line))))
(define results
  (map (lambda (channel)
         (catch #t
           (lambda () (validate channel) #t)
           (lambda (key . args)
             (format (current-error-port) "FAIL ~a: ~s ~s\n" channel key args)
             #f))) channels))
(exit (if (every identity results) 0 1))
