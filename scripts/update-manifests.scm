;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; guix repl -L guix scripts/update-manifests.scm stable beta nightly
(use-modules (rust-toolchain manifest) (rust-toolchain database)
             (guix utils) (guix build utils) (guix build syscalls)
             (ice-9 match) (ice-9 regex) (ice-9 textual-ports)
             (ice-9 pretty-print) (srfi srfi-1))

(define (fetch-official url destination)
  (unless (string-prefix? "https://static.rust-lang.org/dist/" url)
    (error "not an official Rust dist URL" url))
  (unless (zero? (system* "curl" "--fail" "--silent" "--show-error"
                         "--location" "--proto" "=https" "--proto-redir" "=https"
                         "--connect-timeout" "30" "--max-time" "180"
                         "--output" destination url))
    (error "manifest download failed" url)))

(define (read-official-checksum path filename)
  (let* ((text (call-with-input-file path get-string-all))
         (fields (string-tokenize text)))
    (unless (and (= 2 (length fields)) (sha256-hex? (car fields))
                 (member (cadr fields) (list filename (string-append "*" filename))))
      (error "malformed official checksum response" path))
    (car fields)))

(define* (update-manifests channels #:key (directory manifests-directory)
                           (fetch fetch-official))
  (unless (and (pair? channels) (every channel? channels))
    (error "expected stable, beta, nightly, nightly-DATE or VERSION" channels))
  ;; Nothing under DIRECTORY is touched until every download, digest, parse,
  ;; and requested identity has been validated.
  (call-with-temporary-directory
   (lambda (temporary)
     (let ((downloads
            (map
             (lambda (channel n)
               (let* ((url (channel-manifest-url channel))
                      (raw (string-append temporary "/" (number->string n) ".toml"))
                      (checksum (string-append raw ".sha256")))
                 (fetch url raw)
                 (fetch (string-append url ".sha256") checksum)
                 (let ((hash (read-official-checksum checksum (basename url))))
                   (unless (string=? hash (file-sha256 raw))
                     (error "official manifest checksum mismatch; nothing published" channel))
                   (let* ((manifest (read-manifest raw))
                          (version (car (string-tokenize (manifest-version manifest))))
                          (date (manifest-date manifest)))
                     (unless
                         (cond ((string-prefix? "nightly-" channel)
                                (and (string=? (substring channel 8) date)
                                     (string-contains version "-nightly")))
                               ((string=? channel "nightly") (string-contains version "-nightly"))
                               ((string=? channel "beta") (string-contains version "-beta"))
                               ((string=? channel "stable")
                                (string-match "^[0-9]+\\.[0-9]+\\.[0-9]+$" version))
                               (else (string=? channel version)))
                       (error "manifest identity does not match requested channel" channel version date))
                     (list channel raw hash manifest
                           (cond ((string=? channel "stable") (list channel version))
                                 ((string=? channel "nightly")
                                  (list channel (string-append "nightly-" date)))
                                 (else (list channel))))))))
             (delete-duplicates channels) (iota (length (delete-duplicates channels))))))
       (mkdir-p directory)
       (let ((lock (lock-file (string-append directory "/.update.lock") "a0")))
         (dynamic-wind
           (const #t)
           (lambda ()
             (let* ((index (string-append directory "/index.scm"))
                    (old (if (file-exists? index) (read-manifest-index index) '()))
                    (new old) (updates '()))
               (for-each
                (match-lambda
                  ((channel raw hash manifest aliases)
                   (let ((entry (list (string-append "snapshots/" hash ".toml") hash)))
                     (for-each
                      (lambda (alias)
                        (let ((previous (assoc-ref updates alias))
                              (pinned (and (not (member alias '("stable" "beta" "nightly")))
                                           (assoc-ref old alias))))
                          (when (or (and previous (not (equal? previous entry)))
                                    (and pinned (not (equal? pinned entry))))
                            (error "conflicting or changed immutable channel" alias))
                          (set! updates (acons alias entry updates))
                          (set! new (acons alias entry (alist-delete alias new))))) aliases))))
                downloads)
               (set! new (sort new (lambda (a b) (string<? (car a) (car b)))))
               ;; Check existing immutable paths before publishing anything.
               (for-each
                (match-lambda
                  ((_ _ hash _ _)
                   (let ((path (string-append directory "/snapshots/" hash ".toml")))
                     (when (and (file-exists? path) (not (string=? hash (file-sha256 path))))
                       (error "existing immutable snapshot is corrupt" path))))) downloads)
               (mkdir-p (string-append directory "/snapshots"))
               (for-each
                (match-lambda
                  ((channel raw hash manifest _)
                   (format #t "~a: old ~a -> new ~a (~a; ~a)~%"
                           channel (or (assoc-ref old channel) "absent") hash
                           (manifest-date manifest) (manifest-version manifest))
                   (let* ((previous (and (assoc channel old)
                                         (resolve-manifest channel #:directory directory)))
                          (before (if previous (manifest-ref (manifest-data previous) "pkg") '()))
                          (after (manifest-ref (manifest-data manifest) "pkg")))
                     (define (targets packages)
                       (append-map
                        (lambda (pkg)
                          (map (lambda (target) (cons (cons (car pkg) (car target)) (cdr target)))
                               (manifest-ref (cdr pkg) "target"))) packages))
                     (let* ((a (targets before)) (b (targets after))
                            (added (lset-difference equal? (map car b) (map car a)))
                            (removed (lset-difference equal? (map car a) (map car b)))
                            (changed (count (lambda (entry)
                                              (let ((old (assoc (car entry) a)))
                                                (and old (not (equal? old entry))))) b)))
                       (format #t "Manifest diff: packages +~s -~s; targets +~a -~a changed ~a~%"
                               (lset-difference equal? (map car after) (map car before))
                               (lset-difference equal? (map car before) (map car after))
                               (length added) (length removed) changed)))
                   (let ((path (string-append directory "/snapshots/" hash ".toml")))
                     (unless (file-exists? path)
                       (let* ((port (mkstemp (string-append directory "/snapshots/.new-XXXXXX")))
                              (temp (port-filename port)))
                         (close-port port)
                         (dynamic-wind
                           (const #t)
                           (lambda ()
                             (copy-file raw temp)
                             (call-with-input-file temp fsync)
                             (chmod temp #o444) (link temp path))
                           (lambda () (delete-file temp)))))))) downloads)
               (let* ((port (mkstemp (string-append directory "/.index-XXXXXX")))
                      (temp (port-filename port)))
                 (dynamic-wind
                   (const #t)
                   (lambda ()
                     (pretty-print new port) (force-output port) (fsync port)
                     (close-port port) (chmod temp #o644)
                     (read-manifest-index temp)
                     (format #t "Index diff (- old, + new):~%")
                     (for-each (lambda (entry) (format #t "- ~s~%" entry)) (lset-difference equal? old new))
                     (for-each (lambda (entry) (format #t "+ ~s~%" entry)) (lset-difference equal? new old))
                     (rename-file temp index))
                   (lambda ()
                     (unless (port-closed? port) (close-port port))
                     (when (file-exists? temp) (delete-file temp)))))
               (format #t "Verified snapshots published; no commit created.~%")
               new))
           (lambda () (unlock-file lock))))))))

(when (equal? (canonicalize-path (car (command-line)))
              (canonicalize-path (current-filename)))
  (update-manifests (cdr (command-line))))
