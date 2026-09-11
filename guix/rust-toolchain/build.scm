;;; SPDX-License-Identifier: GPL-3.0-or-later
(define-module (rust-toolchain build)
  #:use-module (guix build utils)
  #:use-module (ice-9 popen)
  #:use-module (rnrs bytevectors)
  #:use-module (rnrs io ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (install-toolchain host-elf?))

;; ELF64, little endian, EM_X86_64, ET_EXEC or ET_DYN, not filenames.
(define (host-elf? file)
  (and (eq? 'regular (stat:type (lstat file)))
       (call-with-input-file file
         (lambda (port)
           (let ((h (get-bytevector-n port 20)))
             (and (bytevector? h) (= 20 (bytevector-length h))
                  (equal? '(127 69 76 70 2 1)
                          (take (bytevector->u8-list h) 6))
                  (= 62 (bytevector-u16-ref h 18 (endianness little)))
                  (memv (bytevector-u16-ref h 16 (endianness little)) '(2 3))))))))

(define (command-output . args)
  (let* ((port (apply open-pipe* OPEN_READ args))
         (text (get-string-all port))
         (status (close-pipe port)))
    (unless (zero? status) (error "command failed" args status))
    (string-trim-right text)))

(define (install-toolchain out archives tools libraries interpreter linker-path libc)
  (setenv "PATH" (string-join tools ":"))
  (setenv "HOME" (getcwd))
  (for-each
   (lambda (archive index)
     (let ((directory (number->string index)))
       (mkdir directory)
       (with-directory-excursion directory
         (invoke "tar" "xf" archive "--strip-components=1")
         (invoke "bash" "install.sh" (string-append "--prefix=" out)
                 "--disable-ldconfig"))))
   archives (iota (length archives)))
  (let* ((rustlib (string-append out "/lib/rustlib/"))
         (files (find-files out ".*"))
         (host-files
          (filter (lambda (file)
                    (and (or (not (string-prefix? rustlib file))
                             (string-prefix?
                              (string-append rustlib "x86_64-unknown-linux-gnu/") file))
                         (host-elf? file))) files))
         (local-libs (filter (lambda (file) (string-contains (basename file) ".so"))
                             host-files)))
    (for-each
     (lambda (file)
       (when (string-contains (command-output "readelf" "-d" file) "Dynamic section")
          (let* ((old (command-output "patchelf" "--print-rpath" file))
                 (old-paths (if (string-null? old) '() (string-split old #\:)))
                 (needed (filter (lambda (s) (not (string-null? s)))
                                 (string-split (command-output "patchelf" "--print-needed" file)
                                               #\newline)))
                (paths
                 (map
                  (lambda (soname)
                    (let ((local (find (lambda (lib) (string=? (basename lib) soname)) local-libs))
                          (external (find (lambda (dir)
                                            (file-exists? (string-append dir "/" soname))) libraries)))
                      (or (and local (dirname local)) external
                          (error "unresolved host DT_NEEDED" file soname))))
                  needed)))
            (unless (every (lambda (path)
                             (or (string-prefix? "/gnu/store/" path)
                                 (string=? "$ORIGIN" path)
                                 (string-prefix? "$ORIGIN/" path)))
                           old-paths)
              (error "impure upstream RPATH" file old-paths))
            (format #t "ELF ~a\n  NEEDED ~s\n  original RPATH ~s\n" file needed old)
            (invoke "patchelf" "--set-rpath"
                    (string-join (delete-duplicates
                                  (append old-paths paths)) ":") file)
            (when (string-contains (command-output "readelf" "-l" file) "INTERP")
              (invoke "patchelf" "--set-interpreter" interpreter file)))))
     host-files))
  ;; Include GCC as well as Guix's ld wrapper for direct cargo use in a pure shell.
  (mkdir-p (string-append out "/libexec/rust-toolchain"))
  ;; New Rust versions select bundled lld, bypassing Guix's ld wrapper.
  ;; Give native executables runtime paths even in that case.
  (let ((cc (string-append out "/libexec/rust-toolchain/cc")))
    (call-with-output-file cc
      (lambda (port)
        (format port "#!~a\nexec ~a/gcc \"$@\" -Wl,-rpath,~a -Wl,-rpath,~a\n"
                (which "bash") (last linker-path) libc (cadr libraries))))
    (chmod cc #o755))
  (for-each
   (lambda (file)
     (when (and (eq? 'regular (stat:type (lstat file))) (executable-file? file))
       (wrap-program file
         `("PATH" ":" prefix (,(string-append out "/bin")
                               ,(string-append out "/libexec/rust-toolchain")
                               ,@linker-path))
         `("LIBRARY_PATH" ":" suffix (,libc)))))
   (find-files (string-append out "/bin") ".*"))
  #t)
