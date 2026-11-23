; # x-make -- a make on x-lang
;
; ## lib/make/run.x -- the entry
;
; @description A make: rules, prerequisites, mtimes, recipes, the GNU
;   subset the measured Makefiles use.  The fourth and last tool of the
;   self-hosting arc's core set.
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; Usage:
;   x -l make -- [-C dir] [-f makefile] [-eikns] [VAR=value]... [target]...
;
; The module make/run.  Importing it sets the session's globals; main runs
; mk-main on the operands, and with none the session goes on to the REPL.
(module make/run)
(import make/base make-repl-print make-version)
(import make/cli mk-main)
(set! %lang-name "MAKE")
(set! %lang-version make-version)
(set! %repl-prompt "make> ")
(set! %repl-print make-repl-print)

(def main
  (fn (_)
    (let ((ops (rest (Sys args (lit program)))))
      (unless (null? ops) (mk-main ops)))))

(provide make/run main)
