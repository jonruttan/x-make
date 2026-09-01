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
; -include, NAME = | := | ?= | += VALUE, or TARGETS : PREREQS.
;
; The parse STATE is a box list: (vars rules-rev phony cur-or-())
; where cur = (targets prereqs recipes-rev); finishing a rule pushes
; it.  Conditional stack entries: (taking? seen-true? parent-active?).

; fold backslash-newline continuations into single lines
(def %mk-fold-lines
  (fn (_ text)
    (def end (byte-len text))
    (def go
      (fn (self i start acc cur)
        (if (>= i end)
          (reverse
            (let ((last (string-concat
                          (reverse (pair (substring text start i) cur)))))
              (if (= (byte-len last) 0) acc (pair last acc))))
          (if (= (byte-at text i) 10)
            (if (if (> i start) (= (byte-at text (- i 1)) 92) #f)
              ; backslash-newline: joins with a single space
              (self (+ i 1) (+ i 1) acc
                (pair " " (pair (substring text start (- i 1)) cur)))
              (self (+ i 1) (+ i 1)
                (pair (string-concat
                        (reverse (pair (substring text start i) cur)))
                  acc)
                ()))
            (self (+ i 1) start acc cur)))))
    (go 0 0 () ())))

; the # comment strips from an UNQUOTED position (recipes keep theirs)
(def %mk-strip-comment
  (fn (_ s)
    (let ((at (%mk-find s "#")))
      (if (< at 0) s (substring s 0 at)))))

(def %mk-starts?
  (fn (_ s w)
    (def lw (byte-len w))
    (if (< (byte-len s) lw) #f
      (if (string=? (substring s 0 lw) w)
        (if (= (byte-len s) lw) #t
          (%mk-ws? (byte-at s lw)))
        #f))))

; the first : that is outside $(...) -- a rule line's split point
(def %mk-rule-colon
  (fn (_ s)
    (def end (byte-len s))
    (def go
      (fn (self i depth)
        (if (>= i end) (- 0 1)
          (let ((b (byte-at s i)))
            (if (if (= b 40) #t (= b 123))
              (self (+ i 1) (+ depth 1))
              (if (if (= b 41) #t (= b 125))
                (self (+ i 1) (- depth 1))
                (if (if (= b 58) (= depth 0) #f)
                  i
                  (self (+ i 1) depth))))))))
    (go 0 0)))

; NAME op VALUE: answers (name kind value) or nil; kinds rec simple
; cond append
(def %mk-parse-assign
  (fn (_ s)
    (def at (%mk-find s "="))
    (if (< at 0) ()
      (let ((colon (%mk-rule-colon s)))
        ; a rule's colon before the = means this is a rule, not an
        ; assignment (target-specific vars are not carried)
        (if (if (>= colon 0) (< colon (- at 1)) #f)
          ()
          (let ((prev (if (> at 0) (byte-at s (- at 1)) 0)))
            (def kind
              (if (= prev 58) (lit simple)                  ; :=
                (if (= prev 63) (lit cond)                  ; ?=
                  (if (= prev 43) (lit append)              ; +=
                    (lit rec)))))
            (def name-end (if (eq? kind (lit rec)) at (- at 1)))
            (def name (%mk-trim (substring s 0 name-end)))
            (if (= (byte-len name) 0) ()
              (list name kind
                (%mk-trim (substring s (+ at 1) (byte-len s)))))))))))

; --- conditionals ------------------------------------------------------------

; ifeq (A,B) / ifneq (A,B): both sides expanded, compared as text
(def %mk-cond-eq?
  (fn (_ rest-text vars)
    (def t (%mk-trim rest-text))
    (if (if (> (byte-len t) 1) (= (byte-at t 0) 40) #f)
      (let ((inner (substring t 1 (- (byte-len t) 1))))
        (def as (%mk-args inner))
        (if (null? (rest as))
          (Err raise (lit make) "make: ifeq wants (a,b)" ())
          (string=? (%mk-trim (%mk-expand (first as) vars ()))
            (%mk-trim (%mk-expand (first (rest as)) vars ())))))
      (Err raise (lit make) "make: ifeq wants (a,b)" ()))))

(def %mk-cond-def?
  (fn (_ rest-text vars)
    (not (null? (%mk-var-entry vars (%mk-trim rest-text))))))

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

; --- one handler per line kind, so the dispatch below stays shallow ---

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
      (%mk-path
        (%mk-trim
          (%mk-expand (substring bare (if optional 8 7) (byte-len bare))
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
    (def bare (%mk-trim (%mk-strip-comment line)))
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
    (if (%mk-starts? line "ifeq")
      (%mk-c-push
        (if active (%mk-cond-eq? (substring line 4 (byte-len line)) vars) #f)
        active conds)
      (if (%mk-starts? line "ifneq")
        (%mk-c-push
          (if active
            (not (%mk-cond-eq? (substring line 5 (byte-len line)) vars))
            #f)
          active conds)
        (if (%mk-starts? line "ifdef")
          (%mk-c-push
            (if active
              (%mk-cond-def? (substring line 5 (byte-len line)) vars)
              #f)
            active conds)
          (if (%mk-starts? line "ifndef")
            (%mk-c-push
              (if active
                (not (%mk-cond-def? (substring line 6 (byte-len line)) vars))
                #f)
              active conds)
            (if (%mk-starts? line "else")
              (%mk-c-else conds)
              (if (%mk-starts? line "endif")
                (%mk-c-endif conds)
                (if (not active)
                  conds
                  (if (if (> (byte-len line) 0) (= (byte-at line 0) 9) #f)
                    (%mk-c-recipe line st conds)
                    (%mk-c-bare line st conds)))))))))))

; one assignment, per kind
(def %mk-assign!
  (fn (_ vars name kind text)
    (if (eq? kind (lit simple))
      (%mk-var-set! vars name (lit simple) (%mk-expand text vars ()))
      (if (eq? kind (lit cond))
        (if (null? (%mk-var-entry vars name))
          (%mk-var-set! vars name (lit rec) text)
          ())
        (if (eq? kind (lit append))
          (let ((e (%mk-var-entry vars name)))
            (if (null? e)
              (%mk-var-set! vars name (lit rec) text)
              (%mk-var-set! vars name (first (rest e))
                (string-append (rest (rest e)) (string-append " " text)))))
          (%mk-var-set! vars name (lit rec) text))))))

; a rule line: close the previous rule, open this one; .PHONY collects
(def %mk-rule-line!
  (fn (_ st bare colon)
    (def vars (first st))
    (def targets
      (%mk-words (%mk-expand (substring bare 0 colon) vars ())))
    (def prereqs
      (%mk-words
        (%mk-expand (substring bare (+ colon 1) (byte-len bare)) vars ())))
    (%mk-close-rule! st)
    (if (if (pair? targets) (string=? (first targets) ".PHONY") #f)
      (set-first! (rest (rest st))
        (append prereqs (first (rest (rest st)))))
      (if (null? targets)
        ()
        (set-first! (rest (rest (rest st)))
          (list targets prereqs ()))))))

; the entry: text to (vars-box rules phony), rules in file order
(def mk-parse
  (fn (_ text vars)
    (def st (list vars () () ()))
    (%mk-parse-lines! (%mk-fold-lines text) st ())
    (%mk-close-rule! st)
    (list vars
      (reverse (first (rest st)))
      (first (rest (rest st))))))
