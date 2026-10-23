;;; SPDX-License-Identifier: GPL-3.0-or-later
(define-module (rust-toolchain proxy)
  #:use-module (rust-toolchain component)
  #:use-module (rust-toolchain database)
  #:use-module (rust-toolchain package)
  #:use-module (guix build-system gnu)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module ((guix licenses) #:prefix license:)
  #:export (rust-toolchain-entry rust-toolchain-entry?
            rust-toolchain-entry-selector rust-toolchain-entry-package
            rust-toolchain-proxies %rust-toolchain-proxies))

(define project-directory
  (dirname (dirname (dirname
                     (canonicalize-path
                      (search-path %load-path "rust-toolchain/proxy.scm"))))))

(define proxy-source
  (local-file (string-append project-directory "/src/proxy.c")))

(define-record-type <rust-toolchain-entry>
  (make-rust-toolchain-entry selector package)
  rust-toolchain-entry?
  (selector rust-toolchain-entry-selector)
  (package rust-toolchain-entry-package))

(define* (rust-toolchain-entry selector #:key (profile 'default)
                                (components '()) (targets '()))
  "Return one declared Rust toolchain and its immutable package.
SELECTOR must be present in the bundled manifest index."
  (unless (channel? selector)
    (error "invalid Rust toolchain selector" selector))
  (make-rust-toolchain-entry
   selector
   (rust-toolchain selector #:profile profile
                   #:components components #:targets targets)))

(define (entry-by-selector entries selector)
  (find (lambda (entry)
          (string=? selector (rust-toolchain-entry-selector entry)))
        entries))

(define (validate-default entries name value)
  (unless (or (not value) (string? value))
    (error (string-append "invalid default " name " Rust selector") value))
  (when (and value (not (entry-by-selector entries value)))
    (error (string-append "default " name " is not a declared toolchain") value)))

(define (registry-file entries default-stable default-beta default-nightly)
  (define (line selector entry)
    (list selector "\t" (file-append (rust-toolchain-entry-package entry) "/bin") "\n"))
  (define (default-line name selector)
    (and selector (not (string=? name selector))
         (line name (entry-by-selector entries selector))))
  (apply mixed-text-file "rust-toolchain-proxy-registry"
         (append (or (default-line "stable" default-stable) '())
                 (or (default-line "beta" default-beta) '())
                 (or (default-line "nightly" default-nightly) '())
                 (append-map (lambda (entry)
                               (line (rust-toolchain-entry-selector entry) entry))
                             entries))))

(define* (rust-toolchain-proxies #:key (toolchains '())
                                 (default-stable #f)
                                 (default-beta #f)
                                 (default-nightly #f))
  "Return rustup-style proxies backed only by declared immutable packages.
TOOLCHAINS is a list of `rust-toolchain-entry' values.  Logical channel names
resolve to the optional declared defaults; no invocation downloads a toolchain."
  (unless (and (list? toolchains) (every rust-toolchain-entry? toolchains))
    (error "toolchains must be rust-toolchain-entry values" toolchains))
  (unless (= (length toolchains)
             (length (delete-duplicates (map rust-toolchain-entry-selector toolchains))))
    (error "duplicate declared Rust toolchain selector" toolchains))
  (validate-default toolchains "stable" default-stable)
  (validate-default toolchains "beta" default-beta)
  (validate-default toolchains "nightly" default-nightly)
  (let ((registry (registry-file toolchains default-stable default-beta default-nightly)))
    (package
      (name "rust-toolchain-proxies")
      (version "0.2.0")
      (source #f)
      (build-system gnu-build-system)
      (arguments
       (list
        #:tests? #f
        #:phases
        #~(modify-phases %standard-phases
            (delete 'unpack)
            (delete 'configure)
            (replace 'build
              (lambda _
                (invoke "gcc" "-std=c11" "-O2" "-Wall" "-Wextra" "-Werror"
                        (string-append "-DREGISTRY=\"" #$registry "\"")
                        #$proxy-source "-o" "rust-toolchain-proxy")))
            (replace 'install
              (lambda _
                (let ((bin (string-append #$output "/bin")))
                  (mkdir-p bin)
                  (install-file "rust-toolchain-proxy" bin)
                  (for-each
                   (lambda (name)
                     (symlink "rust-toolchain-proxy" (string-append bin "/" name)))
                    '("cargo" "rustc" "rustdoc" "rust-analyzer"))))))))
      (supported-systems '("x86_64-linux"))
      (home-page "https://rust-lang.org/")
      (synopsis "Static rustup-style proxies for declared Guix Rust toolchains")
      (description "Select declared immutable Rust toolchains without rustup,
runtime downloads, mutable toolchain state, or Guix invocation.")
      (license license:gpl3+))))

(define %rust-toolchain-proxies (rust-toolchain-proxies))
