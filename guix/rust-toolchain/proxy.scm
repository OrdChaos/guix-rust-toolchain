;;; SPDX-License-Identifier: GPL-3.0-or-later
(define-module (rust-toolchain proxy)
  #:use-module (rust-toolchain component)
  #:use-module (rust-toolchain database)
  #:use-module (rust-toolchain package)
  #:use-module (gnu packages bash)
  #:use-module (guix build-system gnu)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module ((guix licenses) #:prefix license:)
  #:export (rust-toolchain-entry rust-toolchain-entry?
             rust-toolchain-entry-selector rust-toolchain-entry-profile
             rust-toolchain-entry-components rust-toolchain-entry-targets
             rust-toolchain-entry-package
             rust-toolchain-proxies %rust-toolchain-proxies))

(define project-directory
  (dirname (dirname (dirname
                     (canonicalize-path
                      (search-path %load-path "rust-toolchain/proxy.scm"))))))

(define proxy-source
  (local-file (string-append project-directory "/src/proxy.c")))

(define channel-modules
  (local-file (string-append project-directory "/guix") #:recursive? #t))

(define-record-type <rust-toolchain-entry>
  (make-rust-toolchain-entry selector profile components targets package)
  rust-toolchain-entry?
  (selector rust-toolchain-entry-selector)
  (profile rust-toolchain-entry-profile)
  (components rust-toolchain-entry-components)
  (targets rust-toolchain-entry-targets)
  (package rust-toolchain-entry-package))

(define %profiles '("minimal" "default" "complete"))

(define (profile-name profile)
  (let ((name (if (symbol? profile) (symbol->string profile) profile)))
    (unless (member name %profiles)
      (error "invalid Rust toolchain profile" profile))
    name))

(define (registry-token? value)
  (and (string? value)
       (not (string-null? value))
       (not (string-index value #\tab))
       (not (string-index value #\newline))
       (not (string-index value #\return))
       (not (string-index value #\,))))

(define (registry-list values)
  (if (null? values) ""
      (string-append (car values) "," (registry-list (cdr values)))))

(define* (rust-toolchain-entry selector #:key (profile 'default)
                                 (components '()) (targets '()))
  "Return one declared Rust toolchain and its immutable package.
SELECTOR must be present in the bundled manifest index."
  (let ((profile (profile-name profile)))
    (unless (and (channel? selector)
                 (list? components) (every registry-token? components)
                 (list? targets) (every registry-token? targets))
      (error "invalid static Rust toolchain capabilities"
             selector components targets))
    (make-rust-toolchain-entry
     selector profile components targets
     (rust-toolchain selector #:profile (string->symbol profile)
                     #:components components #:targets targets))))

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
    (list selector "\t" (file-append (rust-toolchain-entry-package entry) "/bin")
          "\t" (rust-toolchain-entry-profile entry)
          "\t" (registry-list (rust-toolchain-entry-components entry))
          "\t" (registry-list (rust-toolchain-entry-targets entry)) "\n"))
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
                     '("cargo" "rustc" "rustdoc" "rust-analyzer"))
                   (call-with-output-file (string-append bin "/rust-toolchain-shell")
                     (lambda (port)
                       (format port "#!~a~%exec guix shell -L ~a -e '~a' \"$@\"~%"
                               #$(file-append bash "/bin/sh")
                               #$channel-modules
                               "(begin (use-modules (rust-toolchain toolchain-file)) (rust-toolchain-from-current-directory))")))
                   (chmod (string-append bin "/rust-toolchain-shell") #o555)))))))
      (supported-systems '("x86_64-linux"))
      (home-page "https://rust-lang.org/")
      (synopsis "Static rustup-style proxies for declared Guix Rust toolchains")
      (description "Select declared immutable Rust toolchains without rustup,
runtime downloads, mutable toolchain state, or Guix invocation.  The separate
rust-toolchain-shell command explicitly enters a Guix shell for the current
project's toolchain file.")
      (license license:gpl3+))))

(define %rust-toolchain-proxies (rust-toolchain-proxies))
