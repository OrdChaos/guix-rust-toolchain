;;; SPDX-License-Identifier: GPL-3.0-or-later
(define-module (rust-toolchain toolchain-file)
  #:use-module (rust-toolchain component)
  #:use-module (rust-toolchain manifest)
  #:use-module (rust-toolchain package)
  #:use-module (rust-toolchain toml)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:export (rust-toolchain-spec-from-file find-rust-toolchain-file
            rust-toolchain-from-file rust-toolchain-from-current-directory))

(define %toolchain-fields '("channel" "profile" "components" "targets"))

(define (string-list? value)
  (and (list? value) (every string? value)))

(define (spec-from-data data path)
  (unless (and (list? data)
               (= (length data) 1)
               (assoc "toolchain" data))
    (error "toolchain file must contain only [toolchain]" path))
  (let* ((table (assoc-ref data "toolchain"))
         (unknown (filter (lambda (entry)
                            (not (member (car entry) %toolchain-fields)))
                          table))
         (channel (assoc-ref table "channel"))
         (profile (or (assoc-ref table "profile") "default"))
         (components (or (assoc-ref table "components") '()))
         (targets (or (assoc-ref table "targets") '())))
    (unless (null? unknown)
      (error "unsupported rust-toolchain.toml field" (caar unknown)))
    (unless (and (string? channel)
                 (member profile '("minimal" "default" "complete"))
                 (string-list? components)
                 (string-list? targets))
      (error "invalid [toolchain] configuration" path))
    (make-rust-toolchain-spec channel #:profile (string->symbol profile)
                              #:components components #:targets targets)))

(define (legacy-line text)
  (let ((without-final-newline
         (cond ((string-suffix? "\r\n" text)
                (substring text 0 (- (string-length text) 2)))
               ((string-suffix? "\n" text)
                (substring text 0 (- (string-length text) 1)))
               (else text))))
    (and (not (string-any (lambda (character)
                            (or (char=? character #\newline)
                                (char=? character #\return)))
                          without-final-newline))
         (string-trim-both without-final-newline))))

(define (rust-toolchain-spec-from-file path)
  (let* ((text (call-with-input-file path get-string-all))
         (line (and (not (string-suffix? ".toml" path))
                    (legacy-line text))))
    (if line
        (begin
          (when (string-null? line) (error "empty rust-toolchain file" path))
          (make-rust-toolchain-spec line))
        (call-with-input-string text
          (lambda (port) (spec-from-data (read-rust-toml port) path))))))

(define* (find-rust-toolchain-file #:optional (start (getcwd)))
  (let loop ((directory (canonicalize-path start)))
    (let ((legacy (string-append directory "/rust-toolchain"))
          (toml (string-append directory "/rust-toolchain.toml")))
      (cond ((file-exists? legacy) legacy)
            ((file-exists? toml) toml)
            (else
             (let ((parent (dirname directory)))
               (and (not (string=? parent directory)) (loop parent))))))))

(define (package-from-spec spec)
  (rust-toolchain (rust-toolchain-spec-channel spec)
                  #:profile (rust-toolchain-spec-profile spec)
                  #:components (rust-toolchain-spec-components spec)
                  #:targets (rust-toolchain-spec-targets spec)))

(define (rust-toolchain-from-file path)
  (package-from-spec (rust-toolchain-spec-from-file path)))

(define* (rust-toolchain-from-current-directory #:optional (start (getcwd)))
  (let ((path (find-rust-toolchain-file start)))
    (package-from-spec
     (if path (rust-toolchain-spec-from-file path)
         (make-rust-toolchain-spec "stable")))))
