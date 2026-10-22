; # x-make -- a make on x-lang
;
; ## mk/base.x -- the tool, assembled
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)

(module mk/base)
(import mk/cli mk-argv mk-main mk-parse-cli mk-run)
(import mk/parse mk-parse)
(import mk/prims)

(def make-version "0.1.0")

(def make-repl-print
  (fn (_ result)
    (unless (null? result) (write result))
    (newline)))

(provide mk/base
  make-repl-print make-version)
