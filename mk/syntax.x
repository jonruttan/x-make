; # x-make -- a make on x-lang
;
; ## mk/syntax.x -- the make highlighting grammar
;
; @description The grammar x/tool/syntax colours makefiles with: comments,
;   macro expansions, the directives as keywords, the special targets as
;   constants, and the assignment and rule operators.
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; lang.xon's (grammar make ...) form names this module, and x/tool/syntax
; imports it the first time a file needs the grammar, in whatever process is
; colouring: vi's, a REPL's, an HTML renderer's.  So it imports x-lang
; libraries and never the tool.
;
; Tokens are lexical, as a highlighter's are.  $(...) and ${...} are each one
; expansion, the expansions and function calls inside them included; $X, $@
; and $$ are one too.  Make has no quoting of its own, so a quote is a
; word's byte.  A recipe's line is read with the same tokens: its macros
; colour, and the shell words else and export colour as the directives do.
; The directives are POSIX's and GNU's, so any makefile reads, not only the
; ones x-make runs.

(module mk/syntax)
(import x/type/list)
(import x/reader/lexer)
(import x/tool/syntax)

(def mk-syntax-directives
  (list "include" "-include" "sinclude" "ifeq" "ifneq" "ifdef" "ifndef"
        "else" "endif" "define" "endef" "override" "export" "unexport"
        "undefine" "private" "vpath"))

(def mk-syntax-special-targets
  (list ".PHONY" ".SUFFIXES" ".DEFAULT" ".PRECIOUS" ".INTERMEDIATE"
        ".SECONDARY" ".SILENT" ".IGNORE" ".POSIX" ".NOTPARALLEL"
        ".DELETE_ON_ERROR" ".EXPORT_ALL_VARIABLES" ".ONESHELL"
        ".SECONDEXPANSION" ".LOW_RESOLUTION_TIME" ".WAIT"))

; A word is a run of the bytes no other token starts with: not a blank, #, $,
; a paren or a brace, a backslash, or a byte of an operator: : ; = | ? + !.
; A byte above 127 is a word's, read with either sign.
(def %mk-syntax-word
  (list (pair 1 8) (pair 11 12) (pair 14 31) 34 (pair 37 39) 42 (pair 44 57)
        60 62 (pair 64 91) (pair 93 122) (pair 126 255) (pair -128 -1)))

; The byte after a $ that makes a one-byte expansion: any but a paren, a
; brace or a blank.
(def %mk-syntax-short
  (list (pair 33 39) (pair 41 122) 124 (pair 126 255) (pair -128 -1)))

; The spans an expansion holds, each (NAME CLOSE ESC OPENS): a paren or a
; brace inside one opens another, so $(patsubst %.c,%.o,$(SRC)) is one.
(def %mk-syntax-contexts
  (list
    (list (lit paren) 41 () (list (pair "(" (lit paren)) (pair "${" (lit brace))))
    (list (lit brace) 125 () (list (pair "{" (lit brace)) (pair "$(" (lit paren))))))

(def %mk-syntax-rules
  (list
    (Lexer run (lit blank) " \t\r\n" " \t\r\n")
    (Lexer until (lit comment) "#" "\n" (lit to-end))
    (Lexer nested (lit expand) "$(" (lit paren) %mk-syntax-contexts (lit to-end))
    (Lexer nested (lit expand) "${" (lit brace) %mk-syntax-contexts (lit to-end))
    (Lexer pattern (lit expand) (list (list "$" 1 1) (list %mk-syntax-short 1 1)))
    (Lexer escape (lit escape) 92)
    (Lexer table (lit op)
      (list "=" ":=" "::=" ":::=" "?=" "+=" "!=" ":" "::" "|" ";"))
    (Lexer run (lit word) %mk-syntax-word %mk-syntax-word)
    (Lexer any (lit other))))

(def %mk-syntax-word-class
  (fn (_ text)
    (match
      ((List includes? text mk-syntax-directives) (lit keyword))
      ((List includes? text mk-syntax-special-targets) (lit constant))
      (#t ()))))

; A line that starts with neither a blank nor a tab, below a line that does
; not end in a backslash, is taken to start outside any expansion, so spans
; need not read the makefile from its top.
(def %mk-syntax-bref (prim-ref (lit str) (lit byte-ref)))
(def %mk-syntax-cint (prim-ref (lit char) (lit ->int)))
(def %mk-syntax-blen (prim-ref (lit str) (lit byte-len)))
(def %mk-syntax-byte (fn (_ s i) (%mk-syntax-cint (%mk-syntax-bref s i))))

(def %mk-syntax-sync
  (fn (_ s ls)
    (match
      ((>= ls (%mk-syntax-blen s)) #f)
      ((List includes? (%mk-syntax-byte s ls) (list 9 10 32)) #f)
      ((< ls 2) #t)
      (#t (not (= (%mk-syntax-byte s (- ls 2)) 92))))))

(Syntax register!
  (let ((g (Syntax make (lit make) %mk-syntax-rules
             (list (pair (lit comment) (lit comment))
                   (pair (lit expand) (lit name))
                   (pair (lit escape) (lit escape))
                   (pair (lit op) (lit operator))
                   (pair (lit word) %mk-syntax-word-class)))))
    (g sync %mk-syntax-sync)
    g))

(provide mk/syntax mk-syntax-directives mk-syntax-special-targets)
