; # x-make -- a make on x-lang
;
; ## mk/base.x -- the tool, assembled
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)

(import mk/prims)

(provide mk/base make-version mk-parse mk-run mk-argv mk-parse-cli
  mk-main %make-repl-print)

(def make-version "0.1.0")

(def %make-repl-print
  (fn (_ result)
    (unless (null? result) (write result))
    (newline)))

(include-once "./expand.x")
(include-once "./parse.x")
(include-once "./run.x")
(include-once "./cli.x")
