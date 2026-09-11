;;; Run: guix repl -L guix scripts/validate-cross.scm
(use-modules (rust-toolchain package)
             (gnu packages base)
             (gnu packages cross-base)
             (guix build-system trivial)
             (guix derivations)
             (guix gexp)
             (guix packages)
             (guix store))

(define rust
  (rust-toolchain "stable" #:profile 'minimal
                  #:targets '("wasm32-unknown-unknown"
                              "aarch64-unknown-linux-gnu")))
(define cross-gcc (cross-gcc-toolchain "aarch64-linux-gnu"))

(define check
  (package
    (name "rust-toolchain-cross-check")
    (version (package-version rust))
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:builder
      (with-imported-modules '((guix build utils))
        #~(begin
            (use-modules (guix build utils) (ice-9 popen) (srfi srfi-13)
                         (rnrs bytevectors)
                         (rnrs io ports))
            (define (output . arguments)
              (let* ((port (apply open-pipe* OPEN_READ arguments))
                     (text (get-string-all port))
                     (status (close-pipe port)))
                (unless (zero? status) (error "inspection failed" arguments))
                text))
            (setenv "PATH"
                    (string-append #$(file-append rust "/bin") ":"
                                   #$(file-append cross-gcc "/bin")))
            (setenv "HOME" (getcwd))
            (call-with-output-file "hello.rs"
              (lambda (port)
                (display "fn main() { println!(\"cross-ok\"); }\n" port)))
            (invoke "rustc" "--target=wasm32-unknown-unknown" "hello.rs"
                    "-o" "hello.wasm")
            (let ((magic (call-with-input-file "hello.wasm"
                           (lambda (port) (get-bytevector-n port 4)))))
              (unless (and (= (bytevector-length magic) 4)
                           (equal? (map (lambda (index)
                                          (bytevector-u8-ref magic index))
                                        '(0 1 2 3))
                                   '(0 97 115 109)))
                (error "invalid WebAssembly output")))
            (invoke "rustc" "--target=aarch64-unknown-linux-gnu"
                    "-C" "linker=aarch64-linux-gnu-gcc" "hello.rs"
                    "-o" "hello-aarch64")
            (let ((header (output #$(file-append binutils "/bin/readelf")
                                  "-h" "hello-aarch64"))
                  (program (output #$(file-append binutils "/bin/readelf")
                                   "-l" "hello-aarch64")))
              (unless (and (string-contains header "Class:                             ELF64")
                           (string-contains header "Data:                              2's complement, little endian")
                           (string-contains header "Machine:                           AArch64")
                           (string-contains program
                                            "Requesting program interpreter: /gnu/store/"))
                (error "invalid AArch64 ELF output" header program)))
            (unless (and (file-exists? "hello.wasm")
                         (file-exists? "hello-aarch64"))
              (error "cross outputs missing"))
            (mkdir #$output)
            (copy-file "hello.wasm" (string-append #$output "/hello.wasm"))
            (copy-file "hello-aarch64"
                       (string-append #$output "/hello-aarch64"))))))
    (home-page "https://www.rust-lang.org")
    (synopsis "Rust binary toolchain cross-compilation check")
    (description "Build-only integration test for Rust target standard libraries
and the Guix AArch64 GNU cross toolchain.")
    (license #f)))

(with-store store
  (let ((drv (package-derivation store check)))
    (format #t "BUILD cross ~a\n" (derivation-file-name drv))
    (force-output)
    (build-derivations store (list drv))
    (format #t "PASS cross ~a\n" (derivation->output-path drv))))
