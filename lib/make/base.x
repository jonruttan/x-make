; # x-make -- a make on x-lang
;
; ## make/base.x -- the tool, assembled
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)

(module make/base)
(import make/cli mk-main mk-parse-cli mk-run)
(import make/parse mk-parse)
(import make/prims)

(def make-version "0.1.0")

(def make-repl-print
  (fn (_ result)
    (unless (null? result) (write result))
    (newline)))

(provide make/base
  make-repl-print make-version)
