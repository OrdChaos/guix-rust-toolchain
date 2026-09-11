;;; SPDX-License-Identifier: GPL-3.0-or-later
(define-module (rust-toolchain database)
  #:use-module (rust-toolchain manifest)
  #:use-module (gcrypt hash)
  #:use-module (guix base16)
  #:use-module (ice-9 match)
  #:use-module (ice-9 regex)
  #:use-module (srfi srfi-1)
  #:export (resolve-manifest read-manifest-index manifests-directory
            file-sha256 channel? channel-manifest-url))

(define manifests-directory
  (string-append (dirname (dirname (dirname
                  (canonicalize-path (search-path %load-path "rust-toolchain/database.scm")))))
                 "/manifests"))

(define (file-sha256 path)
  (bytevector->base16-string (file-hash (hash-algorithm sha256) path)))

(define (channel? channel)
  (and (string? channel)
       (or (member channel '("stable" "beta" "nightly"))
           (and (string-prefix? "nightly-" channel) (iso-date? (substring channel 8)))
           (string-match "^[0-9]+\\.[0-9]+\\.[0-9]+$" channel)) #t))

(define (channel-manifest-url channel)
  (unless (channel? channel) (error "unsupported Rust channel" channel))
  (string-append "https://static.rust-lang.org/dist/"
                 (if (string-prefix? "nightly-" channel)
                     (string-append (substring channel 8) "/channel-rust-nightly.toml")
                     (string-append "channel-rust-" channel ".toml"))))

(define (read-manifest-index path)
  (with-fluids ((read-eval? #f))
    (call-with-input-file path
      (lambda (port)
        (let ((data (read port)))
          (unless (and (eof-object? (read port)) (list? data)
                       (every (match-lambda
                                (((? channel?) (? string? file) (? sha256-hex? hash))
                                 (string=? file (string-append "snapshots/" hash ".toml")))
                                (_ #f)) data)
                       (= (length data) (length (delete-duplicates (map car data)))))
            (error "invalid manifest index" path))
          data)))))

(define* (resolve-manifest channel #:key (directory manifests-directory))
  (unless (channel? channel) (error "unsupported Rust channel" channel))
  (let ((entry (assoc-ref (read-manifest-index (string-append directory "/index.scm")) channel)))
    (unless entry (error "Rust channel absent from bundled index; run updater" channel))
    (let ((path (string-append directory "/" (car entry))))
      (unless (string=? (file-sha256 path) (cadr entry))
        (error "bundled manifest checksum mismatch" path))
      (read-manifest path))))
