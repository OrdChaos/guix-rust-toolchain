;;; SPDX-License-Identifier: GPL-3.0-or-later
(define-module (rust-toolchain component)
  #:use-module (rust-toolchain manifest)
  #:use-module (rust-toolchain database)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (make-rust-toolchain-spec rust-toolchain-spec?
            rust-toolchain-spec-channel rust-toolchain-spec-profile
            rust-toolchain-spec-components rust-toolchain-spec-targets
            resolve-components component? component-name component-target
            component-url component-sha256 component-available?))

(define-record-type <rust-toolchain-spec>
  (%make-spec channel profile components targets)
  rust-toolchain-spec?
  (channel rust-toolchain-spec-channel)
  (profile rust-toolchain-spec-profile)
  (components rust-toolchain-spec-components)
  (targets rust-toolchain-spec-targets))

(define* (make-rust-toolchain-spec channel #:key (profile 'default)
                                   (components '()) (targets '()))
  (unless (and (channel? channel) (or (symbol? profile) (string? profile))
               (list? components) (every string? components)
               (list? targets) (every string? targets))
    (error "invalid Rust toolchain specification" channel profile components targets))
  (%make-spec channel profile components targets))

(define-record-type <component>
  (%make-component name target url sha256 available?)
  component?
  (name component-name) (target component-target) (url component-url)
  (sha256 component-sha256) (available? component-available?))

(define (resolve-components manifest spec host)
  (let* ((data (manifest-data manifest))
         (host-data (manifest-ref data "pkg" "rust" "target" host))
         (profile (rust-toolchain-spec-profile spec))
         (names (manifest-ref data "profiles" (if (symbol? profile) (symbol->string profile) profile))))
    (unless host-data (error "Rust host absent from manifest" host))
    (unless (eq? #t (manifest-ref host-data "available"))
      (error "Rust host unavailable" host))
    (unless (and (list? names) (every string? names))
      (error "Rust profile absent or malformed" profile))
    (let ((offered (append (or (manifest-ref host-data "components") '())
                           (or (manifest-ref host-data "extensions") '()))))
      (define (rename name)
        (let ((alias (manifest-ref data "renames" name)))
          (if alias
              (let ((to (manifest-ref alias "to")))
                (unless (string? to) (error "malformed component rename" name)) to)
              name)))
      (define (host-target name)
        (let ((entry (find (lambda (entry)
                             (and (equal? name (manifest-ref entry "pkg"))
                                  (member (manifest-ref entry "target") (list host "*")))) offered)))
          (and entry (manifest-ref entry "target"))))
      (define (requested name)
        (let* ((name (rename name)) (target (host-target name)))
          (unless target (error "component absent for Rust host" name host))
          (cons name target)))
      (define (resolve pair)
        (let* ((name (car pair)) (target (cdr pair))
               (entry (manifest-ref data "pkg" name "target" target)))
          (unless entry (error "component/target absent from manifest" name target))
          (unless (eq? #t (manifest-ref entry "available"))
            (error "component/target unavailable" name target))
          (let* ((xz? (assoc "xz_url" entry))
                 (url (manifest-ref entry (if xz? "xz_url" "url")))
                 (hash (manifest-ref entry (if xz? "xz_hash" "hash"))))
            (unless (and (string? url) (string-prefix? "https://" url) (sha256-hex? hash))
              (error "invalid component download metadata" name target))
            (%make-component name target url hash #t))))
      (map resolve
           (delete-duplicates
            (append
             ;; Profiles describe all platforms. Only host-applicable entries
             ;; participate; explicit requests, unlike profile entries, fail.
             (filter-map (lambda (name)
                           (let* ((name (rename name)) (target (host-target name)))
                             (and target (cons name target)))) names)
             (map requested (rust-toolchain-spec-components spec))
             (map (lambda (target) (cons "rust-std" target))
                  (rust-toolchain-spec-targets spec))) equal?)))))
