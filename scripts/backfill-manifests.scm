;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Backfill the bundled index with exact stable releases and dated nightly
;;; manifests published since START (default 2026-01-01) through END (default
;;; today).  Reuses the hardened updater; the only network access is the
;;; official Rust distribution server.
;;; guix repl -L guix scripts/backfill-manifests.scm [START [END]]
(use-modules (rust-toolchain manifest)
             (rust-toolchain database)
             (guix build utils)
             (ice-9 match)
             (ice-9 popen)
             (srfi srfi-1)
             (srfi srfi-19))

(load (string-append (dirname (canonicalize-path (current-filename)))
                     "/update-manifests.scm"))

(define (iso->julian iso)
  (date->julian-day
   (make-date 0 0 0 12
              (string->number (substring iso 8 10))
              (string->number (substring iso 5 7))
              (string->number (substring iso 0 4)) 0)))

(define (julian->iso julian)
  (date->string (julian-day->date julian) "~Y-~m-~d"))

(define (run-curl args)
  (let* ((port (apply open-pipe* OPEN_READ "curl"
                      (append '("--silent" "--show-error"
                                "--location" "--proto" "=https" "--proto-redir" "=https"
                                "--connect-timeout" "30" "--max-time" "180"
                                "--retry" "5" "--retry-all-errors" "--retry-delay" "2")
                              args
                              '("--write-out" "%{http_code}"))))
         (code (string-trim-both (get-string-all port))))
    (close-pipe port) code))

(define (url-exists? url)
  (let loop ((attempt 1))
    (let ((code (run-curl (list "--output" "/dev/null" url))))
      (cond ((string=? code "200") #t)
            ((string=? code "404") #f)
            ((>= attempt 6)
             (error "cannot determine availability of official URL" code url))
            (else (sleep 3) (loop (+ attempt 1)))))))

(define (retrying-fetch url destination)
  (unless (string-prefix? "https://static.rust-lang.org/dist/" url)
    (error "not an official Rust dist URL" url))
  (let loop ((attempt 1) (delay 2))
    (let ((status (system* "curl" "--fail" "--silent" "--show-error"
                           "--location" "--proto" "=https" "--proto-redir" "=https"
                           "--connect-timeout" "30" "--max-time" "180"
                           "--retry" "5" "--retry-all-errors" "--retry-delay" "2"
                           "--output" destination url)))
      (if (zero? status) #t
          (if (>= attempt 8)
              (error "manifest download failed" url)
              (begin (sleep delay) (loop (+ attempt 1) (min (* delay 2) 30))))))))

(define (stable-versions-since cutoff)
  (call-with-temporary-directory
   (lambda (directory)
     (let ((current (string-append directory "/stable.toml")))
       (retrying-fetch "https://static.rust-lang.org/dist/channel-rust-stable.toml"
                       current)
       (let* ((version (car (string-tokenize (manifest-version (read-manifest current)))))
              (parts (string-split version #\.))
              (major (car parts))
              (start-minor (string->number (cadr parts))))
         (let loop ((minor start-minor) (acc '()))
           (define entries
             (let inner ((patch 0) (found '()))
               (let* ((version (string-append major "." (number->string minor)
                                              "." (number->string patch)))
                      (url (channel-manifest-url version)))
                 (if (url-exists? (string-append url ".sha256"))
                     (let ((path (string-append directory "/" version ".toml")))
                       (retrying-fetch url path)
                       (inner (+ patch 1)
                              (cons (cons version (manifest-date (read-manifest path)))
                                    found)))
                     (reverse found)))))
           (cond ((null? entries) acc)
                 ((string<? (cdr (last entries)) cutoff) acc)
                 (else
                  (loop (- minor 1)
                        (append (map car
                                     (filter (lambda (entry)
                                               (not (string<? (cdr entry) cutoff)))
                                             entries))
                                acc))))))))))

(define (nightly-channels start end)
  (let loop ((day (iso->julian start)) (last (iso->julian end)) (acc '()))
    (if (> day last)
        (reverse acc)
        (loop (+ day 1) last
              (cons (string-append "nightly-" (julian->iso day)) acc)))))

(define (update-one channel)
  (catch #t
    (lambda ()
      (update-manifests (list channel) #:fetch retrying-fetch)
      #t)
    (lambda (key . args)
      (format #t "    deferred ~a: ~a ~a~%" channel key args)
      #f)))

(define (backfill start end)
  (format #t "Collecting exact stable releases since ~a...~%" start)
  (let* ((stable (stable-versions-since start))
         (nightly (nightly-channels start end))
         (channels (append stable nightly))
         (total (length channels)))
    (format #t "Stable releases: ~{~a~^, ~}~%" stable)
    (format #t "Dated nightlies: ~a (~a..~a)~%" (length nightly) start end)
    (let loop ((todo channels) (round 1) (seen 0))
      (if (null? todo)
          (format #t "~%Backfill complete; ~a channels processed; no commit created.~%"
                  total)
          (let ((failed '()))
            (for-each
             (lambda (channel)
               (set! seen (+ seen 1))
               (format #t "[round ~a, ~a/~a] ~a~%" round seen (length todo) channel)
               (force-output)
               (unless (update-one channel)
                 (set! failed (cons channel failed))))
             todo)
            (cond ((null? failed)
                   (format #t "~%Backfill complete; ~a channels processed; no commit created.~%"
                           total))
                  ((>= round 6)
                   (error "channels still failing after retries" (reverse failed)))
                  (else
                   (format #t "~%Round ~a: ~a channel(s) deferred; retrying in 10s...~%"
                           round (length failed))
                   (force-output)
                   (sleep 10)
                   (loop (reverse failed) (+ round 1) 0))))))))

(when (equal? (canonicalize-path (car (command-line)))
              (canonicalize-path (current-filename)))
  (match (cdr (command-line))
    ((start) (backfill start start))
    ((start end) (backfill start end))
    (() (backfill "2026-01-01" (date->string (current-date) "~Y-~m-~d")))))
