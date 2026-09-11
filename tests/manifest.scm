(use-modules (rust-toolchain manifest) (rust-toolchain toml) (rust-toolchain database)
             (srfi srfi-64))
(test-begin "manifest")
(define runner (test-runner-current))
(define (parse s) (call-with-input-string s read-rust-toml))
(test-equal "array tables preserved" '((("pkg" . "a")) (("pkg" . "b")))
  (manifest-ref (parse "[[x.items]]\npkg='a'\n[[x.items]]\npkg='b'\n") "x" "items"))
(test-equal "strings, escapes, multiline arrays and comments"
  '("a\nb" "c") (assoc-ref (parse "x = [\n\"a\\nb\", # note\n'c',\n]\n") "x"))
(test-equal "quoted wildcard" #f
  (manifest-ref (parse "[pkg.source.target.'*']\navailable=false\n")
                "pkg" "source" "target" "*" "available"))
(test-equal "CRLF" '(("a" . #t) ("b" . #f)) (parse "a=true\r\nb=false\r\n"))
(test-equal "Unicode escapes" "AZ" (assoc-ref (parse "a=\"\\u0041\\U0000005a\"\n") "a"))
(for-each (lambda (s) (test-error "malformed or unsupported fails" #t (parse s)))
          '("x = 'open" "x=true\nx=false" "[a]\nx=true\n[a]\ny=false"
            "x=23" "x=\"\"\"multiline\"\"\"" "x=[true false]"
            "[[a]]\nx=true\n[a.b]\nx=false" "x='ok' trailing"
            "[broken\nx=true" "x=\"\\uD800\"" "a=false\n[a.b]\nx=true"
            "a.b=true" "a={b=true}" "\ra=true" "a=[\rtrue]" "#\x01\n"))
(define stable (resolve-manifest "1.98.1"))
(define nightly (resolve-manifest "nightly-2026-09-10"))
(test-equal "stable date" "2026-09-03" (manifest-date stable))
(test-assert "stable version" (string-prefix? "1.98.1 " (manifest-version stable)))
(test-equal "nightly date" "2026-09-10" (manifest-date nightly))
(test-assert "real array tables"
  (> (length (manifest-ref (manifest-data stable) "pkg" "rust" "target"
                           "x86_64-unknown-linux-gnu" "extensions")) 50))
(test-assert "open target wasm32-wasip3"
  (manifest-ref (manifest-data nightly) "pkg" "rust-std" "target" "wasm32-wasip3"))
(test-end "manifest")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
