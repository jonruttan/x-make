; # x-make -- a make on x-lang
;
; ## mk/expand.x -- $(...) expansion
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; The variable table is a BOX of ((name . (KIND . text)) ...): kind rec
; expands at every use (=), simple expanded once at assignment (:=),
; lock a command-line override no file assignment may touch.  The
; automatics ($@ $< $^ $*) ride in as an overlay alist checked first.
;
; Functions carried: shell wildcard findstring if subst patsubst
; basename dir notdir strip -- the set the measured Makefiles use, plus
; the trivial siblings.  $(shell) and $(wildcard) honour %mk-cwd, the
; -C prefix (there is no chdir anywhere in this bundle: commands run
; under `cd PREFIX &&` and paths join it).

(def %mk-cwd "")   ; the -C prefix, "" for here; set by the CLI

(def %mk-path
  (fn (_ rel)
    (if (= (byte-len %mk-cwd) 0) rel
      (if (if (> (byte-len rel) 0) (= (byte-at rel 0) 47) #f)
        rel
        (string-append %mk-cwd (string-append "/" rel))))))

; --- small text helpers (bytes, module-level) --------------------------------

(def %mk-b->s
  (fn (_ b) (list->string (list (integer->char b)))))

(def %mk-ws?
  (fn (_ b) (if (= b 32) #t (if (= b 9) #t (= b 10)))))

(def %mk-trim
  (fn (_ s)
    (def end (byte-len s))
    (def a (let ((go (fn (self i)
                       (if (>= i end) i
                         (if (%mk-ws? (byte-at s i)) (self (+ i 1)) i)))))
             (go 0)))
    (def b (let ((go (fn (self i)
                       (if (<= i a) i
                         (if (%mk-ws? (byte-at s (- i 1))) (self (- i 1)) i)))))
             (go end)))
    (substring s a b)))

(def %mk-words-go
  (fn (self s end i start acc)
    (if (>= i end)
      (reverse (if (> i start) (pair (substring s start i) acc) acc))
      (if (%mk-ws? (byte-at s i))
        (self s end (+ i 1) (+ i 1)
          (if (> i start) (pair (substring s start i) acc) acc))
        (self s end (+ i 1) start acc)))))
(def %mk-words
  (fn (_ s) (%mk-words-go s (byte-len s) 0 0 ())))

(def %mk-join
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
(def %mk-find
  (fn (_ s t) (%mk-find-go s t (byte-len s) (byte-len t) 0)))

; literal replace-all
(def %mk-subst
  (fn (_ from to text)
    (def lf (byte-len from))
    (if (= lf 0) text
      (let ((go (fn (self s acc)
                  (let ((at (%mk-find s from)))
                    (if (< at 0)
                      (string-concat (reverse (pair s acc)))
                      (self (substring s (+ at lf) (byte-len s))
                        (pair to (pair (substring s 0 at) acc))))))))
        (go text ())))))

; --- the variable table ------------------------------------------------------

(def %mk-var-entry
  (fn (_ vars name)
    (def go
      (fn (self es)
        (if (null? es) ()
          (if (string=? (first (first es)) name)
            (first es)
            (self (rest es))))))
    (go (first vars))))

; a file assignment; a lock entry wins over it silently
(def %mk-var-set!
  (fn (_ vars name kind text)
    (def e (%mk-var-entry vars name))
    (if (null? e)
      (set-first! vars (pair (pair name (pair kind text)) (first vars)))
      (if (eq? (first (rest e)) (lit lock))
        ()
        (set-first! vars
          (pair (pair name (pair kind text))
            (%mk-var-del (first vars) name)))))))

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
                    (if (= b 46) #t (if (= b 43) #t (if (= b 40) #t
                      (if (= b 41) #t (if (= b 123) #t (if (= b 125) #t
                        (if (= b 124) #t (if (= b 94) #t (if (= b 36) #t
                          (= b 92))))))))))))
    (def go
      (fn (self i acc)
        (if (>= i end) (regex-compile (string-concat (reverse acc)))
          (let ((b (byte-at pat i)))
            (if (= b 42) (self (+ i 1) (pair ".*" acc))          ; *
              (if (= b 63) (self (+ i 1) (pair "." acc))         ; ?
                (if (= b 91)                                     ; [
                  (let ((close (let ((go2 (fn (self2 j)
                                            (if (>= j end) j
                                              (if (= (byte-at pat j) 93)
                                                (+ j 1)
                                                (self2 (+ j 1)))))))
                                 (go2 (+ i 1)))))
                    (self close (pair (substring pat i close) acc)))
                  (if (special? b)
                    (self (+ i 1)
                      (pair (string-append "\\" (%mk-b->s b)) acc))
                    (self (+ i 1) (pair (%mk-b->s b) acc))))))))))
    (go 0 ())))

(def %mk-glob-one
  (fn (_ pat)
    (def slash
      (let ((go (fn (self i last)
                  (if (>= i (byte-len pat)) last
                    (self (+ i 1)
                      (if (= (byte-at pat i) 47) i last))))))
        (go 0 (- 0 1))))
    (def dirpart (if (< slash 0) "" (substring pat 0 slash)))
    (def basepat (if (< slash 0) pat
                   (substring pat (+ slash 1) (byte-len pat))))
    (def scan-dir (%mk-path (if (= (byte-len dirpart) 0) "." dirpart)))
    (if (not (file-exists? scan-dir)) ()
      (let ((rx (%mk-glob-rx basepat)))
        (def names
          (filter (fn (_ n)
                    (if (string=? n ".") #f
                      (if (string=? n "..") #f (regex-match n rx))))
            (file-list-dir scan-dir)))
        (map (fn (_ n)
               (if (= (byte-len dirpart) 0) n
                 (string-append dirpart (string-append "/" n))))
          (%mk-sort names))))))

; --- expansion ---------------------------------------------------------------

(def %mk-expand ())

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
      (let ((e (%mk-var-entry vars name)))
        (if (null? e) ""
          (if (eq? (first (rest e)) (lit rec))
            (%mk-expand (rest (rest e)) vars autos)
            (rest (rest e))))))))

; split an argument string on top-level commas (paren/brace aware)
(def %mk-args
  (fn (_ s)
    (def end (byte-len s))
    (def go
      (fn (self i depth start acc)
        (if (>= i end)
          (reverse (pair (substring s start end) acc))
          (let ((b (byte-at s i)))
            (if (if (= b 40) #t (= b 123))
              (self (+ i 1) (+ depth 1) start acc)
              (if (if (= b 41) #t (= b 125))
                (self (+ i 1) (- depth 1) start acc)
                (if (if (= b 44) (= depth 0) #f)
                  (self (+ i 1) depth (+ i 1)
                    (pair (substring s start i) acc))
                  (self (+ i 1) depth start acc))))))))
    (go 0 0 0 ())))

(def %mk-fn-name?
  (fn (_ s nm)
    (def ln (byte-len nm))
    (if (<= (byte-len s) ln) #f
      (if (string=? (substring s 0 ln) nm)
        (%mk-ws? (byte-at s ln))
        #f))))

; the inner text of one $(...): a function call or a variable reference
(def %mk-inner
  (fn (_ inner vars autos)
    (def call
      (fn (_ nm)
        (%mk-args
          (%mk-trim
            (substring inner (+ (byte-len nm) 1) (byte-len inner))))))
    (if (%mk-fn-name? inner "shell")
      (let ((cmd (%mk-expand (first (call "shell")) vars autos)))
        (def full (if (= (byte-len %mk-cwd) 0) cmd
                    (string-append "cd " (string-append %mk-cwd
                      (string-append " && " cmd)))))
        (def r (proc-capture (list "/bin/sh" "-c" full)))
        ; GNU: trailing newlines dropped, interior newlines to spaces
        (%mk-join (%mk-words (rest r)) " "))
    (if (%mk-fn-name? inner "wildcard")
      (let ((pats (%mk-words (%mk-expand (first (call "wildcard")) vars autos))))
        (def go
          (fn (self ps acc)
            (if (null? ps) (%mk-join (reverse acc) " ")
              (self (rest ps)
                (let ((ms (%mk-glob-one (first ps))))
                  (if (null? ms) acc (pair (%mk-join ms " ") acc)))))))
        (go pats ()))
    (if (%mk-fn-name? inner "findstring")
      (let ((as (call "findstring")))
        (def f (%mk-expand (first as) vars autos))
        (def in (%mk-expand (first (rest as)) vars autos))
        (if (< (%mk-find in f) 0) "" f))
    (if (%mk-fn-name? inner "if")
      (let ((as (call "if")))
        (if (> (byte-len (%mk-trim (%mk-expand (first as) vars autos))) 0)
          (%mk-expand (first (rest as)) vars autos)
          (if (null? (rest (rest as))) ""
            (%mk-expand (first (rest (rest as))) vars autos))))
    (if (%mk-fn-name? inner "subst")
      (let ((as (call "subst")))
        (%mk-subst (%mk-expand (first as) vars autos)
          (%mk-expand (first (rest as)) vars autos)
          (%mk-expand (first (rest (rest as))) vars autos)))
    (if (%mk-fn-name? inner "patsubst")
      (let ((as (call "patsubst")))
        (%mk-patsubst (%mk-expand (first as) vars autos)
          (%mk-expand (first (rest as)) vars autos)
          (%mk-expand (first (rest (rest as))) vars autos)))
    (if (%mk-fn-name? inner "basename")
      (%mk-join
        (map (fn (_ w) (%mk-basename w))
          (%mk-words (%mk-expand (first (call "basename")) vars autos)))
        " ")
    (if (%mk-fn-name? inner "dir")
      (%mk-join
        (map (fn (_ w) (%mk-dirpart w))
          (%mk-words (%mk-expand (first (call "dir")) vars autos)))
        " ")
    (if (%mk-fn-name? inner "notdir")
      (%mk-join
        (map (fn (_ w) (%mk-notdir w))
          (%mk-words (%mk-expand (first (call "notdir")) vars autos)))
        " ")
    (if (%mk-fn-name? inner "strip")
      (%mk-join (%mk-words (%mk-expand (first (call "strip")) vars autos)) " ")
    ; a variable reference; a computed name expands first
    (let ((name (if (< (%mk-find inner "$") 0) inner
                  (%mk-expand inner vars autos))))
      (%mk-lookup name vars autos))))))))))))))

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

; pattern word substitution: one % in PAT is the stem
(def %mk-patsubst
  (fn (_ pat repl text)
    (def pc (%mk-find pat "%"))
    (def go
      (fn (self ws acc)
        (if (null? ws) (%mk-join (reverse acc) " ")
          (self (rest ws) (pair (%mk-pat-one (first ws) pat repl pc) acc)))))
    (go (%mk-words text) ())))

(def %mk-pat-one
  (fn (_ w pat repl pc)
    (if (< pc 0)
      (if (string=? w pat) repl w)
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
          (let ((stem (substring w lp (- lw ls))))
            (%mk-subst "%" stem repl))
          w)))))

; the scanner: text with $-references to text without
(set! %mk-expand
  (fn (_ text vars autos)
    (def end (byte-len text))
    (def go
      (fn (self i acc)
        (if (>= i end) (string-concat (reverse acc))
          (let ((b (byte-at text i)))
            (if (not (= b 36))                              ; $
              (self (+ i 1) (pair (%mk-b->s b) acc))
              (if (>= (+ i 1) end)
                (string-concat (reverse (pair "$" acc)))
                (let ((n (byte-at text (+ i 1))))
                  (if (= n 36)                              ; $$
                    (self (+ i 2) (pair "$" acc))
                    (if (if (= n 40) #t (= n 123))          ; $( ${
                      (let ((close (if (= n 40) 41 125)))
                        (def open n)
                        (def scan
                          (fn (self2 j depth)
                            (if (>= j end) j
                              (let ((c (byte-at text j)))
                                (if (= c open) (self2 (+ j 1) (+ depth 1))
                                  (if (= c close)
                                    (if (= depth 0) j
                                      (self2 (+ j 1) (- depth 1)))
                                    (self2 (+ j 1) depth)))))))
                        (def endp (scan (+ i 2) 0))
                        (self (+ endp 1)
                          (pair
                            (%mk-inner (substring text (+ i 2) endp)
                              vars autos)
                            acc)))
                      ; single-character reference: $X, $@, $<, $^, $*
                      (self (+ i 2)
                        (pair (%mk-lookup (%mk-b->s n) vars autos)
                          acc)))))))))))
    (go 0 ())))
