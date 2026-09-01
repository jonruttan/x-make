; # x-make -- a make on x-lang
;
; ## run.x -- THE entry
;
; @description A make: rules, prerequisites, mtimes, recipes, the GNU
;   subset the measured Makefiles use.  The fourth and last tool of the
;   self-hosting arc's core set.
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; Usage:
;   x -l make -- [-C dir] [-f makefile] [-ns] [VAR=value]... [target]...
(import mk/base)

(set! %lang-name "MAKE")
(set! %lang-version make-version)
(set! %repl-prompt "make> ")
(set! %repl-print %make-repl-print)

(unless (null? (mk-argv args))
  (mk-main args))
