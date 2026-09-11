(use-modules (rust-toolchain manifest) (rust-toolchain database)
             (guix utils) (guix build utils) (ice-9 textual-ports)
             (srfi srfi-1) (srfi srfi-64))
(primitive-load (string-append (dirname manifests-directory) "/scripts/update-manifests.scm"))
(test-begin "updater")
(define runner (test-runner-current))
(define fixture (string-append (dirname manifests-directory) "/tests/fixtures/components.toml"))
(define mode 'ok)
(define source fixture)
(define (mock-fetch url destination)
  (unless (string-prefix? "https://static.rust-lang.org/dist/" url)
    (error "non-official URL" url))
  (if (string-suffix? ".sha256" url)
      (call-with-output-file destination
        (lambda (p)
          (if (eq? mode 'malformed-checksum) (display "not-a-checksum" p)
              (format p "~a  ~a~%"
                      (if (eq? mode 'mismatch) (make-string 64 #\0) (file-sha256 source))
                      (basename (substring url 0 (- (string-length url) 7)))))))
      (copy-file source destination)))
(define (state directory)
  (map (lambda (path) (cons path (file-sha256 path)))
       (sort (find-files directory #:directories? #f) string<?)))
(call-with-temporary-directory
 (lambda (tmp)
   (let ((directory (string-append tmp "/manifests")))
     (set! mode 'mismatch)
     (test-error "checksum mismatch" #t
       (update-manifests '("stable") #:directory directory #:fetch mock-fetch))
     (test-assert "mismatch creates no destination" (not (file-exists? directory)))
     (set! mode 'ok)
     (update-manifests '("stable") #:directory directory #:fetch mock-fetch)
     (test-equal "published snapshot resolves" "1.98.1 (fixture)"
       (manifest-version (resolve-manifest "stable" #:directory directory)))
     (test-equal "stable pins exact version" '("1.98.1" "stable")
       (map car (read-manifest-index (string-append directory "/index.scm"))))
     (let ((before (state directory)))
       (update-manifests '("stable") #:directory directory #:fetch mock-fetch)
       (test-equal "idempotent publication" before (state directory))
       (for-each
        (lambda (failure)
          (set! mode failure)
          (test-error "failed verification" #t
            (update-manifests '("stable") #:directory directory #:fetch mock-fetch))
          (test-equal "failed verification writes nothing" before (state directory)))
        '(mismatch malformed-checksum))
       (set! mode 'ok)
       (test-error "wrong pinned version" #t
         (update-manifests '("1.99.0") #:directory directory #:fetch mock-fetch))
       (test-equal "identity mismatch writes nothing" before (state directory))
       (let ((malformed (string-append tmp "/malformed.toml")))
         (call-with-output-file malformed (lambda (p) (display "date = 'unterminated" p)))
         (set! source malformed)
         (test-error "valid digest malformed TOML" #t
           (update-manifests '("stable") #:directory directory #:fetch mock-fetch))
         (test-equal "malformed manifest writes nothing" before (state directory))
         (call-with-output-file malformed
           (lambda (p) (display "manifest-version='2'\ndate='2026-09-10'\n[pkg.rust]\nversion='1.98.1'\n" p)))
         (test-error "valid digest invalid manifest schema" #t
           (update-manifests '("stable") #:directory directory #:fetch mock-fetch))
         (test-equal "bad schema writes nothing" before (state directory)))
       (set! source fixture)
       (test-error "batch validation before any publish" #t
         (update-manifests '("stable" "nightly") #:directory directory #:fetch mock-fetch))
        (test-equal "failed batch writes nothing" before (state directory))
        (let ((changed (string-append tmp "/changed.toml")))
          (call-with-output-file changed
            (lambda (p)
              (display (call-with-input-file fixture get-string-all) p)
              (display "\n# changed bytes, same pinned version\n" p)))
          (set! source changed)
          (test-error "immutable version cannot be rebound" #t
            (update-manifests '("1.98.1") #:directory directory #:fetch mock-fetch))
          (test-equal "immutable conflict writes nothing" before (state directory))))
     (set! source (string-append manifests-directory "/"
                   (cadr (assoc "nightly" (read-manifest-index (string-append manifests-directory "/index.scm"))))))
     (update-manifests '("nightly") #:directory directory #:fetch mock-fetch)
     (test-equal "nightly dated alias" "2026-09-10"
       (manifest-date (resolve-manifest "nightly-2026-09-10" #:directory directory)))
     (let ((before (state directory)))
       (test-error "wrong nightly date" #t
         (update-manifests '("nightly-2026-09-09") #:directory directory #:fetch mock-fetch))
        (test-equal "wrong nightly date writes nothing" before (state directory)))
      (set! source fixture)
      (let ((snapshot (string-append directory "/snapshots/" (file-sha256 fixture) ".toml")))
        (chmod snapshot #o644)
        (call-with-output-file snapshot (lambda (p) (display "corrupt" p)))
        (let ((before (state directory)))
          (test-error "corrupt bundled snapshot rejected" #t
            (resolve-manifest "stable" #:directory directory))
          (test-error "updater cannot overwrite immutable corrupt path" #t
            (update-manifests '("stable") #:directory directory #:fetch mock-fetch))
          (test-equal "corrupt path left untouched" before (state directory)))))))
(for-each (lambda (channel) (test-assert "accepted channel" (channel? channel)))
          '("stable" "beta" "nightly" "nightly-2026-09-10" "1.98.1"))
(for-each (lambda (channel) (test-assert "invalid channel" (not (channel? channel))))
          '("nightly-2026-02-30" "nightly-2026-13-01" "1.98" "../stable" "stable\n"))
(test-end "updater")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
