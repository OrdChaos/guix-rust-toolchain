;;; SPDX-License-Identifier: GPL-3.0-or-later
(define-module (rust-toolchain proxy)
  #:use-module (guix build-system gnu)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages package-management)
  #:export (%rust-toolchain-proxies))

(define project-directory
  (dirname (dirname (dirname
            (canonicalize-path (search-path %load-path "rust-toolchain/proxy.scm"))))))

(define (manifest-source? file stat)
  (let ((name (basename file)))
    (and (not (string=? name ".update.lock"))
         (not (string-prefix? ".index-" name))
         (not (string-prefix? ".new-" name)))))

(define provider-tree
  (file-union "guix-rust-toolchain-provider"
    `(("guix/rust-toolchain"
       ,(local-file (string-append project-directory "/guix/rust-toolchain")
                     #:recursive? #t))
      ("manifests"
       ,(local-file (string-append project-directory "/manifests")
                     #:recursive? #t
                     #:select? manifest-source?)))))

(define proxy-source
  (local-file (string-append project-directory "/src/proxy.c")))

(define %rust-toolchain-proxies
  (package
    (name "rust-toolchain-proxies")
    (version "0.1.0")
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
                      (string-append "-DGUIX=\"" #$(file-append guix "/bin/guix") "\"")
                      (string-append "-DPROVIDER=\"" #$provider-tree "\"")
                      #$proxy-source "-o" "rust-toolchain-proxy")))
          (replace 'install
            (lambda _
              (let ((bin (string-append #$output "/bin")))
                (mkdir-p bin)
                (install-file "rust-toolchain-proxy" bin)
                (for-each
                 (lambda (name)
                   (symlink "rust-toolchain-proxy" (string-append bin "/" name)))
                 '("cargo" "rustc" "rustdoc"
                   "cargo-stable" "rustc-stable" "rustdoc-stable"
                   "cargo-nightly" "rustc-nightly" "rustdoc-nightly"))))))))
    (inputs (list guix))
    (supported-systems '("x86_64-linux"))
    (home-page "https://rust-lang.org/")
    (synopsis "Stateless proxies for Guix-provided Rust toolchains")
    (description "Select project Rust toolchains and realize immutable Guix
packages without using rustup or a mutable toolchain installation database.")
    (license license:gpl3+)))
