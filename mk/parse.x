; # x-make -- a make on x-lang
;
; ## mk/parse.x -- makefile text to rules and variables
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; GNU reads a makefile as an INTERPRETER, not a grammar: conditionals
; evaluate against the variables assigned so far, assignments land as
; they are read, rule lines expand their targets immediately.  So this
; parser is a fold over lines carrying (vars rules phony cur-rule
; cond-stack), with include splicing lines in place.
;
; What a line can be: TAB-led recipe (attached to the current rule),
; blank or comment, ifeq/ifneq/ifdef/ifndef/else/endif, include /
; -include, NAME = | := | ?= | += | != VALUE, or TARGETS : PREREQS.
; The special targets .PHONY, .SILENT and .SUFFIXES collect their
; prerequisites instead of becoming rules.
;
; The parse STATE is a box list: (vars rules-rev phony cur-or-() silent
; suffixes) where cur = (targets prereqs recipes-rev); finishing a rule
; pushes it.  Conditional stack entries: (taking? seen-true?
; parent-active?).

; The lines of a makefile: a backslash-newline continues the line (see
; %mk-fold-go for the two readings), any other backslash and the byte
; after it stand (so a doubled backslash before a newline is no
; continuation), and a last line nothing ended is a line when it has bytes.
(module mk/parse)
(import mk/expand
  mk-args mk-expand mk-find mk-lx-lines-cell mk-path mk-shell-capture
  mk-subst mk-top-at mk-trim mk-var-entry mk-var-set! mk-words mk-ws?)
(import mk/prims
  append byte-at byte-len file-exists? file-read-all lexer-escape
  lexer-make lexer-read lexer-run lexer-table reverse set-first!
  string-append string-concat string=? substring)
(def %mk-lx-lines
  (fn (_)
    (if (null? (first mk-lx-lines-cell))
      (set-first! mk-lx-lines-cell
        (lexer-make
          (list
            (lexer-table (lit cont) (list "\\\n"))
            (lexer-table (lit nl) (list "\n"))
            (lexer-escape (lit esc) 92)
            (lexer-run (lit txt)
              (list (pair 0 9) (pair 11 91) (pair 93 255) (pair -128 -1))
              (list (pair 0 9) (pair 11 91) (pair 93 255) (pair -128 -1))))
          "\n"))
      ())
    (first mk-lx-lines-cell)))

(def %mk-rtrim
  (fn (_ s)
    (def go
      (fn (self i)
        (if (<= i 0) 0
          (if (mk-ws? (byte-at s (- i 1))) (self (- i 1)) i))))
    (substring s 0 (go (byte-len s)))))

; the pieces so far (newest first) without the whitespace that ends them
(def %mk-fold-rtrim
  (fn (self cur)
    (if (null? cur) ()
      (let ((t (%mk-rtrim (first cur))))
        (if (= (byte-len t) 0) (self (rest cur)) (pair t (rest cur)))))))

; a line whose first piece opens with a TAB is a recipe
(def %mk-recipe-pieces?
  (fn (self cur)
    (if (null? cur) #f
      (if (null? (rest cur))
        (if (> (byte-len (first cur)) 0) (= (byte-at (first cur) 0) 9) #f)
        (self (rest cur))))))

; a text piece after a continuation: its leading whitespace goes (ws), or
; one leading TAB, the recipe prefix (tab)
(def %mk-fold-lead
  (fn (_ tx tag lead)
    (match
      ((not (eq? tag (lit txt))) tx)
      ((eq? lead (lit ws))
        (let ((go (fn (self i)
                    (if (>= i (byte-len tx)) i
                      (if (mk-ws? (byte-at tx i)) (self (+ i 1)) i)))))
          (substring tx (go 0) (byte-len tx))))
      ((eq? lead (lit tab))
        (if (if (> (byte-len tx) 0) (= (byte-at tx 0) 9) #f)
          (substring tx 1 (byte-len tx))
          tx))
      (#t tx))))

; POSIX's two readings of a backslash-newline: outside a recipe it and the
; whitespace around it, consecutive ones included, are one space; in a
; recipe it stands, the shell joining the lines, and the next line's
; recipe prefix goes.  LEAD is what the last continuation asks of the
; next piece: nil, ws or tab.
(def %mk-fold-go
  (fn (self ts cur acc lead)
    (if (null? ts)
      (reverse (if (null? cur) acc (pair (string-concat (reverse cur)) acc)))
      (let ((tag (first (first ts))) (tx (first (rest (first ts)))))
        (match
          ((eq? tag (lit nl))
            (self (rest ts) () (pair (string-concat (reverse cur)) acc) ()))
          ((eq? tag (lit cont))
            (if (%mk-recipe-pieces? cur)
              (self (rest ts) (pair "\\\n" cur) acc (lit tab))
              (self (rest ts)
                (if (eq? lead (lit ws)) cur (pair " " (%mk-fold-rtrim cur)))
                acc (lit ws))))
          (#t
            (self (rest ts) (pair (%mk-fold-lead tx tag lead) cur) acc ())))))))

(def %mk-fold-lines
  (fn (_ text)
    (if (= (byte-len text) 0) ()
      (%mk-fold-go (lexer-read (%mk-lx-lines) text) () () ()))))

; the # comment strips from an UNQUOTED position (recipes keep theirs)
(def %mk-strip-comment
  (fn (_ s)
    (let ((at (mk-find s "#")))
      (if (< at 0) s (substring s 0 at)))))

(def %mk-starts?
  (fn (_ s w)
    (def lw (byte-len w))
    (if (< (byte-len s) lw) #f
      (if (string=? (substring s 0 lw) w)
        (if (= (byte-len s) lw) #t
          (mk-ws? (byte-at s lw)))
        #f))))

; the first : outside $(...) -- a rule line's split point, or -1
(def %mk-rule-colon (fn (_ s) (mk-top-at s 58)))

; NAME op VALUE: answers (name label value) or nil; labels rec simple
; cond append shell
(def %mk-parse-assign
  (fn (_ s)
    (def at (mk-top-at s 61))
    (if (< at 0) ()
      (let ((colon (%mk-rule-colon s)))
        ; a rule's colon before the = means this is a rule, not an
        ; assignment (target-specific vars are not carried)
        (if (if (>= colon 0) (< colon (- at 1)) #f)
          ()
          (let ((prev (if (> at 0) (byte-at s (- at 1)) 0)))
            (def label
              (match
                ((= prev 58) (lit simple))                  ; :=
                ((= prev 63) (lit cond))                    ; ?=
                ((= prev 43) (lit append))                  ; +=
                ((= prev 33) (lit shell))                   ; !=
                (#t (lit rec))))
            (def name-end (if (eq? label (lit rec)) at (- at 1)))
            (def name (mk-trim (substring s 0 name-end)))
            (if (= (byte-len name) 0) ()
              (list name label
                (mk-trim (substring s (+ at 1) (byte-len s)))))))))))

; --- conditionals ------------------------------------------------------------

; ifeq (A,B) / ifneq (A,B): both sides expanded, compared as text
(def %mk-cond-eq?
  (fn (_ rest-text vars)
    (def t (mk-trim rest-text))
    (if (if (> (byte-len t) 1) (= (byte-at t 0) 40) #f)
      (let ((inner (substring t 1 (- (byte-len t) 1))))
        (def as (mk-args inner))
        (if (null? (rest as))
          (Err raise (lit make) "make: ifeq wants (a,b)" ())
          (string=? (mk-trim (mk-expand (first as) vars ()))
            (mk-trim (mk-expand (first (rest as)) vars ())))))
      (Err raise (lit make) "make: ifeq wants (a,b)" ()))))

(def %mk-cond-def?
  (fn (_ rest-text vars)
    (not (null? (mk-var-entry vars (mk-trim rest-text))))))

; --- the fold ----------------------------------------------------------------

; finish the current rule into the rules list
(def %mk-close-rule!
  (fn (_ st)
    (def cur (first (rest (rest (rest st)))))
    (if (null? cur) ()
      (set-first! (rest st)
        (pair
          (list (first cur)
            (first (rest cur))
            (reverse (first (rest (rest cur)))))
          (first (rest st)))))
    (set-first! (rest (rest (rest st))) ())))

; st: (vars-box rules-box phony-box cur-box); cur = () or
; (targets prereqs recipes-rev)
(def %mk-line! ())

(def %mk-parse-lines!
  (fn (self lines st conds)
    (if (null? lines) ()
      (self (rest lines) st (%mk-line! (first lines) st conds)))))

; active when every frame of the stack is taking
(def %mk-conds-active?
  (fn (self conds)
    (if (null? conds) #t
      (if (first (first conds)) (self (rest conds)) #f))))

; --- one handler per line variant, so the dispatch below stays shallow ---

(def %mk-c-push
  (fn (_ v active conds) (pair (list v v active) conds)))

(def %mk-c-else
  (fn (_ conds)
    (if (null? conds)
      (Err raise (lit make) "make: else without if" ())
      (let ((frame (first conds)))
        (def parent (first (rest (rest frame))))
        (pair
          (list (if parent (not (first (rest frame))) #f) #t parent)
          (rest conds))))))

(def %mk-c-endif
  (fn (_ conds)
    (if (null? conds)
      (Err raise (lit make) "make: endif without if" ())
      (rest conds))))

(def %mk-c-recipe
  (fn (_ line st conds)
    (def cur (first (rest (rest (rest st)))))
    (if (null? cur)
      (Err raise (lit make) "make: recipe before any target" ())
      (do (set-first! (rest (rest cur))
            (pair (substring line 1 (byte-len line))
              (first (rest (rest cur)))))
          conds))))

(def %mk-c-include
  (fn (_ bare st conds)
    (def vars (first st))
    (def optional (= (byte-at bare 0) 45))
    (def path
      (mk-path
        (mk-trim
          (mk-expand (substring bare (if optional 8 7) (byte-len bare))
            vars ()))))
    (if (file-exists? path)
      (do (%mk-parse-lines! (%mk-fold-lines (file-read-all path)) st ())
          conds)
      (if optional
        conds
        (Err raise (lit make)
          (string-append "make: cannot include " path) ())))))

(def %mk-c-bare
  (fn (_ line st conds)
    (def vars (first st))
    (def bare (mk-trim (%mk-strip-comment line)))
    (if (= (byte-len bare) 0)
      conds
      (if (if (%mk-starts? bare "include") #t (%mk-starts? bare "-include"))
        (%mk-c-include bare st conds)
        (let ((asn (%mk-parse-assign bare)))
          (if (not (null? asn))
            (do (%mk-assign! vars (first asn) (first (rest asn))
                  (first (rest (rest asn))))
                conds)
            (let ((colon (%mk-rule-colon bare)))
              (if (< colon 0)
                (Err raise (lit make)
                  (string-append "make: unreadable line: " bare) ())
                (do (%mk-rule-line! st bare colon)
                    conds)))))))))

; conditional keywords manage the stack whatever the activity;
; everything else only runs when every frame is taking
(set! %mk-line!
  (fn (_ line st conds)
    (def vars (first st))
    (def active (%mk-conds-active? conds))
    (match
      ((%mk-starts? line "ifeq")
        (%mk-c-push
          (if active (%mk-cond-eq? (substring line 4 (byte-len line)) vars) #f)
          active conds))
      ((%mk-starts? line "ifneq")
        (%mk-c-push
          (if active
            (not (%mk-cond-eq? (substring line 5 (byte-len line)) vars))
            #f)
          active conds))
      ((%mk-starts? line "ifdef")
        (%mk-c-push
          (if active
            (%mk-cond-def? (substring line 5 (byte-len line)) vars)
            #f)
          active conds))
      ((%mk-starts? line "ifndef")
        (%mk-c-push
          (if active
            (not (%mk-cond-def? (substring line 6 (byte-len line)) vars))
            #f)
          active conds))
      ((%mk-starts? line "else") (%mk-c-else conds))
      ((%mk-starts? line "endif") (%mk-c-endif conds))
      ((not active) conds)
      ((if (> (byte-len line) 0) (= (byte-at line 0) 9) #f)
        (%mk-c-recipe line st conds))
      (#t (%mk-c-bare line st conds)))))

; one assignment, per label
(def %mk-assign!
  (fn (_ vars name label text)
    (match
      ((eq? label (lit simple))
        (mk-var-set! vars name (lit simple) (mk-expand text vars ())))
      ((eq? label (lit cond))
        (if (null? (mk-var-entry vars name))
          (mk-var-set! vars name (lit rec) text)
          ()))
      ((eq? label (lit append))
        (let ((e (mk-var-entry vars name)))
          (if (null? e)
            (mk-var-set! vars name (lit rec) text)
            (mk-var-set! vars name (first (rest e))
              (string-append (rest (rest e)) (string-append " " text))))))
      ((eq? label (lit shell))
        (mk-var-set! vars name (lit rec)
          (%mk-shell-value (mk-shell-capture (mk-expand text vars ())))))
      (#t (mk-var-set! vars name (lit rec) text)))))

; what != assigns, POSIX's reading: the command's output with its trailing
; newlines gone and every other newline a space
(def %mk-shell-value
  (fn (_ out)
    (def go
      (fn (self i)
        (if (<= i 0) 0
          (if (= (byte-at out (- i 1)) 10) (self (- i 1)) i))))
    (mk-subst "\n" " " (substring out 0 (go (byte-len out))))))

; a rule line: close the previous rule, open this one; the special targets
; collect instead
(def %mk-rule-line!
  (fn (_ st bare colon)
    (def vars (first st))
    (def targets
      (mk-words (mk-expand (substring bare 0 colon) vars ())))
    (def prereqs
      (mk-words
        (mk-expand (substring bare (+ colon 1) (byte-len bare)) vars ())))
    (def special (if (pair? targets) (first targets) ""))
    (%mk-close-rule! st)
    (match
      ((null? targets) ())
      ((string=? special ".PHONY")
        (set-first! (rest (rest st))
          (append prereqs (first (rest (rest st))))))
      ((string=? special ".SILENT") (%mk-silent! st prereqs))
      ((string=? special ".SUFFIXES") (%mk-suffixes! st prereqs))
      (#t
        (set-first! (rest (rest (rest st)))
          (list targets prereqs ()))))))

; .SILENT with no prerequisites silences every recipe (the box holds all);
; with some, theirs
(def %mk-silent!
  (fn (_ st prereqs)
    (def box (rest (rest (rest (rest st)))))
    (match
      ((null? prereqs) (set-first! box (lit all)))
      ((eq? (first box) (lit all)) ())
      (#t (set-first! box (append (first box) prereqs))))))

; .SUFFIXES with no prerequisites clears the list; with some, appends
(def %mk-suffixes!
  (fn (_ st prereqs)
    (def box (rest (rest (rest (rest (rest st))))))
    (set-first! box (if (null? prereqs) () (append (first box) prereqs)))))

; the suffixes every make knows before a makefile adds its own
(def mk-default-suffixes (list ".o" ".c" ".y" ".l" ".s" ".sh"))

; the entry: text to (vars-box rules phony silent suffixes), rules in file
; order
(def mk-parse
  (fn (_ text vars)
    (def st (list vars () () () () mk-default-suffixes))
    (%mk-parse-lines! (%mk-fold-lines text) st ())
    (%mk-close-rule! st)
    (list vars
      (reverse (first (rest st)))
      (first (rest (rest st)))
      (first (rest (rest (rest (rest st)))))
      (first (rest (rest (rest (rest (rest st)))))))))

(provide mk/parse
  mk-parse)
