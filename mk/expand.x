; # x-make -- a make on x-lang
;
; ## mk/expand.x -- $(...) expansion
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; The variable table is a BOX of ((name . (LABEL . text)) ...): label rec
; expands at every use (=), simple expanded once at assignment (:=),
; lock a command-line override no file assignment may touch.  The
; automatics ($@ $< $^ $*) ride in as an overlay alist checked first.
;
; Functions carried: shell wildcard findstring if subst patsubst
; basename dir notdir strip sort -- the set the measured Makefiles use,
; plus the trivial siblings.  $(shell) and $(wildcard) honour mk-cwd, the
; -C prefix (there is no chdir anywhere in this bundle: commands run
; under `cd PREFIX &&` and paths join it).

(module mk/expand)
(import mk/prims
  append byte-at byte-len file-dir? file-exists? file-list-dir filter
  integer->char lexer-escape lexer-make lexer-nested lexer-read
  lexer-run lexer-skip lexer-table lexer-word list->string map
  proc-capture regex-compile regex-match reverse set-first!
  string-append string-concat string=? substring)
(def %mk-cwd "")
(def mk-cwd (fn (_) %mk-cwd))                 ; read by every module
(def mk-cwd! (fn (_ v) (set! %mk-cwd v) ()))   ; set by the command line

(def mk-path
  (fn (_ rel)
    (if (= (byte-len (mk-cwd)) 0) rel
      (if (if (> (byte-len rel) 0) (= (byte-at rel 0) 47) #f)
        rel
        (string-append (mk-cwd) (string-append "/" rel))))))

; --- small text helpers (bytes, module-level) --------------------------------

(def %mk-b->s
  (fn (_ b) (list->string (list (integer->char b)))))

(def mk-ws?
  (fn (_ b) (if (= b 32) #t (if (= b 9) #t (= b 10)))))

(def mk-trim
  (fn (_ s)
    (def end (byte-len s))
    (def a (let ((go (fn (self i)
                       (if (>= i end) i
                         (if (mk-ws? (byte-at s i)) (self (+ i 1)) i)))))
             (go 0)))
    (def b (let ((go (fn (self i)
                       (if (<= i a) i
                         (if (mk-ws? (byte-at s (- i 1))) (self (- i 1)) i)))))
             (go end)))
    (substring s a b)))

; --- the lexers --------------------------------------------------------------
;
; Every scan of text here -- the $-references of an expansion, the words of
; a list, an argument list split at its top-level commas, a rule line split
; at its first top-level colon, a makefile folded into lines -- was a byte
; walk in x at 40 to 80 us a byte.  Each is a rule set the platform's lexer
; reads as native code (mk/prims.x's lexer seam), made on first use and kept.
; What the rules leave to the walk over the tokens: an empty piece between
; two separators, and whether a separator closed the last piece.
;
; The end text appended to every read is chosen outside the run rule's class
; so that it ends a run and is itself no token: $ for an expansion, the
; separator for a split, a newline for lines.

(def %mk-lx-expand-cell (pair () ()))
(def %mk-lx-words-cell (pair () ()))
(def %mk-lx-splits (pair () ()))     ; ((BYTE . LEXER) ...)
(def mk-lx-lines-cell (pair () ()))

; every byte but B, high bytes either way the engine hands them over
(def %mk-class-but
  (fn (_ b) (list (pair 0 (- b 1)) (pair (+ b 1) 255) (pair -128 -1))))

(def %mk-nonblank
  (list (pair 0 8) (pair 11 31) (pair 33 255) (pair -128 -1)))

; $$, $(...) and ${...} with their own kind of bracket nested inside, $X,
; and a run of anything else; a reference left open runs to the end
(def %mk-lx-expand
  (fn (_)
    (if (null? (first %mk-lx-expand-cell))
      (set-first! %mk-lx-expand-cell
        (lexer-make
          (list
            (lexer-table (lit dd) (list "$$"))
            (lexer-nested (lit ref) "$(" (lit p)
              (list (list (lit p) 41 () (list (pair "(" (lit p))))))
            (lexer-nested (lit bref) "${" (lit b)
              (list (list (lit b) 125 () (list (pair "{" (lit b))))))
            (lexer-escape (lit one) 36)
            (lexer-run (lit txt) (%mk-class-but 36) (%mk-class-but 36)))
          "$"))
      ())
    (first %mk-lx-expand-cell)))

(def %mk-lx-words
  (fn (_)
    (if (null? (first %mk-lx-words-cell))
      (set-first! %mk-lx-words-cell
        (lexer-make
          (list (lexer-skip " \t\n")
                (lexer-run (lit w) %mk-nonblank %mk-nonblank))
          " "))
      ())
    (first %mk-lx-words-cell)))

; a split at the byte B wherever it is outside parentheses and braces: the
; separator, and a word that ends before one at depth 0
(def %mk-lx-split-find
  (fn (self b l)
    (if (null? l) ()
      (if (= (first (first l)) b) (rest (first l)) (self b (rest l))))))
(def mk-lx-split
  (fn (_ b)
    (let ((hit (%mk-lx-split-find b (first %mk-lx-splits))))
      (if (null? hit)
        (let ((sep (%mk-b->s b)))
          (let ((l (lexer-make
                     (list
                       (lexer-table (lit sep) (list sep))
                       (lexer-word (lit w) (lit a)
                         (list
                           (list (lit a) () () (list (pair "(" (lit p)) (pair "{" (lit b))))
                           (list (lit p) 41 () (list (pair "(" (lit p))))
                           (list (lit b) 125 () (list (pair "{" (lit b)))))
                         sep))
                     sep)))
            (set-first! %mk-lx-splits (pair (pair b l) (first %mk-lx-splits)))
            l))
        hit))))

; the pieces of a text between its separators, from the tokens: (PIECES .
; CLOSED?), CLOSED? when a separator ended the last one; a separator with
; nothing pending is an empty piece
(def %mk-pieces-go
  (fn (self ts pending acc)
    (if (null? ts)
      (if (null? pending)
        (pair (reverse acc) #t)
        (pair (reverse (pair pending acc)) #f))
      (if (eq? (first (first ts)) (lit sep))
        (self (rest ts) () (pair (if (null? pending) "" pending) acc))
        (self (rest ts) (first (rest (first ts))) acc)))))
(def mk-pieces
  (fn (_ ts) (%mk-pieces-go ts () ())))

; the texts of a run of tokens that has no separators
(def %mk-run-texts
  (fn (self ts acc)
    (if (null? ts) (reverse acc)
      (self (rest ts) (pair (first (rest (first ts))) acc)))))

(def mk-words
  (fn (_ s)
    (if (= (byte-len s) 0) ()
      (%mk-run-texts (lexer-read (%mk-lx-words) s) ()))))

(def mk-join
  (fn (self ws sep)
    (if (null? ws) ""
      (if (null? (rest ws)) (first ws)
        (string-append (first ws)
          (string-append sep (self (rest ws) sep)))))))

(def %mk-str<
  (fn (_ a b)
    (def la (byte-len a))
    (def lb (byte-len b))
    (def go
      (fn (self i)
        (if (>= i la) (< la lb)
          (if (>= i lb) #f
            (let ((ca (byte-at a i)) (cb (byte-at b i)))
              (if (< ca cb) #t
                (if (> ca cb) #f (self (+ i 1)))))))))
    (go 0)))

(def %mk-sort
  (fn (_ ws)
    (def ins
      (fn (self w l)
        (if (null? l) (list w)
          (if (%mk-str< w (first l)) (pair w l)
            (pair (first l) (self w (rest l)))))))
    (def go
      (fn (self l acc)
        (if (null? l) acc (self (rest l) (ins (first l) acc)))))
    (go ws ())))

; a sorted list with each run of equal words cut to one
(def %mk-uniq
  (fn (self l)
    (if (null? l) ()
      (if (if (pair? (rest l)) (string=? (first l) (first (rest l))) #f)
        (self (rest l))
        (pair (first l) (self (rest l)))))))

; substring search: position or -1
(def %mk-find-go
  (fn (self s t ls lt i)
    (if (> (+ i lt) ls) (- 0 1)
      (let ((hit (let ((go2 (fn (self2 j)
                              (if (>= j lt) #t
                                (if (= (byte-at s (+ i j)) (byte-at t j))
                                  (self2 (+ j 1))
                                  #f)))))
                   (go2 0))))
        (if hit i (self s t ls lt (+ i 1)))))))
(def mk-find
  (fn (_ s t) (%mk-find-go s t (byte-len s) (byte-len t) 0)))

; literal replace-all
(def mk-subst
  (fn (_ from to text)
    (def lf (byte-len from))
    (if (= lf 0) text
      (let ((go (fn (self s acc)
                  (let ((at (mk-find s from)))
                    (if (< at 0)
                      (string-concat (reverse (pair s acc)))
                      (self (substring s (+ at lf) (byte-len s))
                        (pair to (pair (substring s 0 at) acc))))))))
        (go text ())))))

; --- the variable table ------------------------------------------------------

(def mk-var-entry
  (fn (_ vars name)
    (def go
      (fn (self es)
        (if (null? es) ()
          (if (string=? (first (first es)) name)
            (first es)
            (self (rest es))))))
    (go (first vars))))

; a file assignment; a lock entry wins over it silently
(def mk-var-set!
  (fn (_ vars name label text)
    (def e (mk-var-entry vars name))
    (if (null? e)
      (set-first! vars (pair (pair name (pair label text)) (first vars)))
      (if (eq? (first (rest e)) (lit lock))
        ()
        (set-first! vars
          (pair (pair name (pair label text))
            (%mk-var-del (first vars) name)))))))

; TEXT onto the end of a simple variable's value, from nothing where it
; has none
(def mk-var-append!
  (fn (_ vars name text)
    (def e (mk-var-entry vars name))
    (mk-var-set! vars name (lit simple)
      (string-append (if (null? e) "" (rest (rest e))) text))))

(def %mk-var-del
  (fn (_ es name)
    (def go
      (fn (self l)
        (if (null? l) ()
          (if (string=? (first (first l)) name)
            (rest l)
            (pair (first l) (self (rest l)))))))
    (go es)))

; --- glob --------------------------------------------------------------------

; glob pattern to an anchored regex: * any run, ? one, [..] verbatim,
; regex specials escaped
(def %mk-glob-rx
  (fn (_ pat)
    (def end (byte-len pat))
    (def special? (fn (_ b)
                    (match
                      ((= b 46) #t)  ((= b 43) #t)  ((= b 40) #t)
                      ((= b 41) #t)  ((= b 123) #t) ((= b 125) #t)
                      ((= b 124) #t) ((= b 94) #t)  ((= b 36) #t)
                      ((= b 92) #t)  (#t #f))))
    (def go
      (fn (self i acc)
        (if (>= i end) (regex-compile (string-concat (reverse acc)))
          (let ((b (byte-at pat i)))
            (match
              ((= b 42) (self (+ i 1) (pair ".*" acc)))          ; *
              ((= b 63) (self (+ i 1) (pair "." acc)))           ; ?
              ((= b 91)                                          ; [
                (let ((close (let ((go2 (fn (self2 j)
                                          (if (>= j end) j
                                            (if (= (byte-at pat j) 93)
                                              (+ j 1)
                                              (self2 (+ j 1)))))))
                               (go2 (+ i 1)))))
                  (self close (pair (substring pat i close) acc))))
              ((special? b)
                (self (+ i 1)
                  (pair (string-append "\\" (%mk-b->s b)) acc)))
              (#t (self (+ i 1) (pair (%mk-b->s b) acc))))))))
    (go 0 ())))

; a component that globs: it has a * ? or [ in it
(def %mk-glob-chars?
  (fn (_ s)
    (def go
      (fn (self i)
        (if (>= i (byte-len s)) #f
          (let ((b (byte-at s i)))
            (if (match ((= b 42) #t) ((= b 63) #t) (#t (= b 91)))
              #t
              (self (+ i 1)))))))
    (go 0)))

; the pieces of S between its B bytes, every one kept: a leading slash
; gives an empty first piece, which the join puts back as the root
(def %mk-split-byte
  (fn (_ s b)
    (def end (byte-len s))
    (def go
      (fn (self i start acc)
        (if (>= i end) (reverse (pair (substring s start end) acc))
          (if (= (byte-at s i) b)
            (self (+ i 1) (+ i 1) (pair (substring s start i) acc))
            (self (+ i 1) start acc)))))
    (go 0 0 ())))

; DIR, nil before the first component, and one more component
(def %mk-join-comp
  (fn (_ dir name)
    (if (null? dir) name (string-append dir (string-append "/" name)))))

; the entries of DIR that match the component COMP, sorted and joined on
; it; nothing where DIR is no directory
(def %mk-glob-names
  (fn (_ dir comp)
    (def scan (mk-path (if (null? dir) "." dir)))
    (if (not (file-dir? scan)) ()
      (let ((rx (%mk-glob-rx comp)))
        (map (fn (_ n) (%mk-join-comp dir n))
          (%mk-sort
            (filter (fn (_ n) (regex-match n rx)) (file-list-dir scan))))))))

(def %mk-concat-map
  (fn (self f l)
    (if (null? l) () (append (f (first l)) (self f (rest l))))))

; the paths a pattern names, component by component: a globbing one is
; matched in every directory reached so far, a plain one joined on; what
; a plain last component names is kept only where it exists.  ** is *,
; as glob(3) reads it: one directory, not every depth.
(def %mk-glob-one
  (fn (_ pat)
    (def go
      (fn (self comps dirs)
        (if (null? comps) dirs
          (let ((c (first comps)))
            (self (rest comps)
              (if (%mk-glob-chars? c)
                (%mk-concat-map (fn (_ d) (%mk-glob-names d c)) dirs)
                (map (fn (_ d) (%mk-join-comp d c)) dirs)))))))
    (filter (fn (_ p) (file-exists? (mk-path p)))
      (go (%mk-split-byte pat 47) (list ())))))

; --- expansion ---------------------------------------------------------------

(def mk-expand ())

; auto overlay, then the table; a rec entry re-expands at use
(def %mk-lookup
  (fn (_ name vars autos)
    (def a
      (let ((go (fn (self es)
                  (if (null? es) ()
                    (if (string=? (first (first es)) name)
                      (first es)
                      (self (rest es)))))))
        (go autos)))
    (if (not (null? a)) (rest a)
      (let ((e (mk-var-entry vars name)))
        (if (null? e) ""
          (if (eq? (first (rest e)) (lit rec))
            (mk-expand (rest (rest e)) vars autos)
            (rest (rest e))))))))

; split an argument string on top-level commas (paren/brace aware): a comma
; at the end opens an empty last argument, and an empty string is one
(def mk-args
  (fn (_ s)
    (let ((cut (mk-pieces (lexer-read (mk-lx-split 44) s))))
      (if (rest cut) (append (first cut) (list "")) (first cut)))))

(def %mk-fn-name?
  (fn (_ s nm)
    (def ln (byte-len nm))
    (if (<= (byte-len s) ln) #f
      (if (string=? (substring s 0 ln) nm)
        (mk-ws? (byte-at s ln))
        #f))))

; the inner text of one $(...): a function call or a variable reference
(def %mk-inner
  (fn (_ inner vars autos)
    (def call
      (fn (_ nm)
        (mk-args
          (mk-trim
            (substring inner (+ (byte-len nm) 1) (byte-len inner))))))
    (match
      ((%mk-fn-name? inner "shell")
        (let ((cmd (mk-expand (first (call "shell")) vars autos)))
          (def full (if (= (byte-len (mk-cwd)) 0) cmd
                      (string-append "cd " (string-append (mk-cwd)
                        (string-append " && " cmd)))))
          (def r (proc-capture (list "/bin/sh" "-c" full)))
          ; GNU: trailing newlines dropped, interior newlines to spaces
          (mk-join (mk-words (rest r)) " ")))
      ((%mk-fn-name? inner "wildcard")
        (let ((pats (mk-words (mk-expand (first (call "wildcard")) vars autos))))
          (def go
            (fn (self ps acc)
              (if (null? ps) (mk-join (reverse acc) " ")
                (self (rest ps)
                  (let ((ms (%mk-glob-one (first ps))))
                    (if (null? ms) acc (pair (mk-join ms " ") acc)))))))
          (go pats ())))
      ((%mk-fn-name? inner "findstring")
        (let ((as (call "findstring")))
          (def f (mk-expand (first as) vars autos))
          (def in (mk-expand (first (rest as)) vars autos))
          (if (< (mk-find in f) 0) "" f)))
      ((%mk-fn-name? inner "if")
        (let ((as (call "if")))
          (if (> (byte-len (mk-trim (mk-expand (first as) vars autos))) 0)
            (mk-expand (first (rest as)) vars autos)
            (if (null? (rest (rest as))) ""
              (mk-expand (first (rest (rest as))) vars autos)))))
      ((%mk-fn-name? inner "subst")
        (let ((as (call "subst")))
          (mk-subst (mk-expand (first as) vars autos)
            (mk-expand (first (rest as)) vars autos)
            (mk-expand (first (rest (rest as))) vars autos))))
      ((%mk-fn-name? inner "patsubst")
        (let ((as (call "patsubst")))
          (%mk-patsubst (mk-expand (first as) vars autos)
            (mk-expand (first (rest as)) vars autos)
            (mk-expand (first (rest (rest as))) vars autos))))
      ((%mk-fn-name? inner "basename")
        (mk-join
          (map (fn (_ w) (%mk-basename w))
            (mk-words (mk-expand (first (call "basename")) vars autos)))
          " "))
      ((%mk-fn-name? inner "dir")
        (mk-join
          (map (fn (_ w) (%mk-dirpart w))
            (mk-words (mk-expand (first (call "dir")) vars autos)))
          " "))
      ((%mk-fn-name? inner "notdir")
        (mk-join
          (map (fn (_ w) (%mk-notdir w))
            (mk-words (mk-expand (first (call "notdir")) vars autos)))
          " "))
      ((%mk-fn-name? inner "strip")
        (mk-join (mk-words (mk-expand (first (call "strip")) vars autos)) " "))
      ((%mk-fn-name? inner "sort")
        (mk-join
          (%mk-uniq
            (%mk-sort (mk-words (mk-expand (first (call "sort")) vars autos))))
          " "))
      (#t
      ; a variable reference; a computed name expands first
      (let ((name (if (< (mk-find inner "$") 0) inner
                    (mk-expand inner vars autos))))
        (%mk-lookup name vars autos))))))

(def %mk-last-slash
  (fn (_ w)
    (def go
      (fn (self i last)
        (if (>= i (byte-len w)) last
          (self (+ i 1) (if (= (byte-at w i) 47) i last)))))
    (go 0 (- 0 1))))

(def %mk-dirpart
  (fn (_ w)
    (let ((s (%mk-last-slash w)))
      (if (< s 0) "./" (substring w 0 (+ s 1))))))

(def %mk-notdir
  (fn (_ w)
    (let ((s (%mk-last-slash w)))
      (if (< s 0) w (substring w (+ s 1) (byte-len w))))))

(def %mk-basename
  (fn (_ w)
    (def dot
      (let ((go (fn (self i last)
                  (if (>= i (byte-len w)) last
                    (self (+ i 1)
                      (if (= (byte-at w i) 46) i
                        (if (= (byte-at w i) 47) (- 0 1) last)))))))
        (go 0 (- 0 1))))
    (if (< dot 0) w (substring w 0 dot))))

; the stem of W against PAT, one % in PAT standing for it: the text the %
; covers, "" where PAT has no % and is W whole, nil where W is not of
; PAT's shape
(def mk-pat-stem
  (fn (_ w pat)
    (def pc (mk-find pat "%"))
    (if (< pc 0) (if (string=? w pat) "" ())
      (let ((pre (substring pat 0 pc)))
        (def suf (substring pat (+ pc 1) (byte-len pat)))
        (def lw (byte-len w))
        (def lp (byte-len pre))
        (def ls (byte-len suf))
        (if (if (>= lw (+ lp ls))
              (if (string=? (substring w 0 lp) pre)
                (string=? (substring w (- lw ls) lw) suf)
                #f)
              #f)
          (substring w lp (- lw ls))
          ())))))

; pattern word substitution: one % in PAT is the stem
(def %mk-patsubst
  (fn (_ pat repl text)
    (def pc (mk-find pat "%"))
    (def go
      (fn (self ws acc)
        (if (null? ws) (mk-join (reverse acc) " ")
          (self (rest ws) (pair (%mk-pat-one (first ws) pat repl pc) acc)))))
    (go (mk-words text) ())))

(def %mk-pat-one
  (fn (_ w pat repl pc)
    (let ((stem (mk-pat-stem w pat)))
      (match
        ((null? stem) w)
        ((< pc 0) repl)
        (#t (mk-subst "%" stem repl))))))

; the inner text of a reference token: $( or ${ off the front, and the
; closer off the end where one closed it -- a reference left open at the
; end of the text runs to the end, as GNU reads it
(def %mk-ref-inner
  (fn (_ tx closer)
    (def end (byte-len tx))
    (if (if (> end 2) (= (byte-at tx (- end 1)) closer) #f)
      (substring tx 2 (- end 1))
      (substring tx 2 end))))

; a one-character reference token: $X, $@, $<, $^, $*; a $ alone at the end
; of the text is itself
(def %mk-one
  (fn (_ tx vars autos)
    (if (< (byte-len tx) 2) tx
      (%mk-lookup (substring tx 1 2) vars autos))))

; the scanner: text with $-references to text without, token by token
(set! mk-expand
  (fn (_ text vars autos)
    (def go
      (fn (self ts acc)
        (if (null? ts) (string-concat (reverse acc))
          (let ((tag (first (first ts))) (tx (first (rest (first ts)))))
            (self (rest ts)
              (pair
                (match
                  ((eq? tag (lit txt)) tx)
                  ((eq? tag (lit dd)) "$")
                  ((eq? tag (lit one)) (%mk-one tx vars autos))
                  ((eq? tag (lit ref)) (%mk-inner (%mk-ref-inner tx 41) vars autos))
                  (#t (%mk-inner (%mk-ref-inner tx 125) vars autos)))
                acc))))))
    (if (= (byte-len text) 0) text
      (go (lexer-read (%mk-lx-expand) text) ()))))

(provide mk/expand
  mk-args mk-cwd mk-expand mk-find mk-join mk-lx-lines-cell mk-lx-split
  mk-pat-stem mk-path mk-pieces mk-subst mk-trim mk-var-append!
  mk-var-entry mk-var-set! mk-words mk-ws? mk-cwd!)
