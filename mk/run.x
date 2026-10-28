; # x-make -- a make on x-lang
;
; ## mk/run.x -- the DAG walk, recipes, the command line
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; The rebuild rule, POSIX's: a target rebuilds when it does not exist,
; a prerequisite was remade, or any prerequisite's mtime is STRICTLY
; newer (equal seconds means up to date -- mtimes are whole seconds
; here).  .PHONY targets always run.  A target with no explicit recipe
; takes an implicit rule's: a pattern rule (%.o: %.c) or a suffix rule
; (.c.o:, over .SUFFIXES), the implied source joining its prerequisites.
; Recipes run one line at a time through /bin/sh -c, under `cd PREFIX
; &&` when -C gave one; @ silences the echo (.SILENT and -s silence
; every one), - forgives the status (-i forgives every one).  Automatic
; variables: $@ $< $^ $* $?.

(module mk/run)
(import mk/expand mk-cwd mk-expand mk-find mk-join mk-path mk-subst)
(import mk/prims
  append byte-at byte-len file-exists? file-stat-mtime filter map
  proc-run string-append string=? substring)

; the switches, set by the command line and read by every module
(def %mk-quiet #f)
(def mk-quiet (fn (_) %mk-quiet))
(def mk-quiet! (fn (_ v) (set! %mk-quiet v) ()))
(def %mk-dry #f)
(def mk-dry (fn (_) %mk-dry))
(def mk-dry! (fn (_ v) (set! %mk-dry v) ()))
(def %mk-keep #f)                                  ; -k
(def mk-keep (fn (_) %mk-keep))
(def mk-keep! (fn (_ v) (set! %mk-keep v) ()))
(def %mk-ignore #f)                                ; -i
(def mk-ignore (fn (_) %mk-ignore))
(def mk-ignore! (fn (_ v) (set! %mk-ignore v) ()))
; what the makefile declared: .SILENT's targets (or all) and .SUFFIXES
(def %mk-silent ())
(def mk-silent! (fn (_ v) (set! %mk-silent v) ()))
(def %mk-suffixes ())
(def mk-suffixes (fn (_) %mk-suffixes))
(def mk-suffixes! (fn (_ v) (set! %mk-suffixes v) ()))

(def %mk-find-rule
  (fn (_ rules target)
    (def go
      (fn (self rs)
        (if (null? rs) ()
          (let ((hit (let ((go2 (fn (self2 ts)
                                  (if (null? ts) #f
                                    (if (string=? (first ts) target) #t
                                      (self2 (rest ts)))))))
                       (go2 (first (first rs))))))
            (if hit (first rs) (self (rest rs)))))))
    (go rules)))

; a pattern rule whose % target matches: answers (stem . rule) or nil
(def %mk-find-pattern
  (fn (_ rules target)
    (def go
      (fn (self rs)
        (if (null? rs) ()
          (let ((t (first (first (first rs)))))
            (def pc (mk-find t "%"))
            (if (< pc 0) (self (rest rs))
              (let ((pre (substring t 0 pc)))
                (def suf (substring t (+ pc 1) (byte-len t)))
                (def lw (byte-len target))
                (def lp (byte-len pre))
                (def ls (byte-len suf))
                (if (if (> lw (+ lp ls))
                      (if (string=? (substring target 0 lp) pre)
                        (string=? (substring target (- lw ls) lw) suf)
                        #f)
                      #f)
                  (pair (substring target lp (- lw ls)) (first rs))
                  (self (rest rs)))))))))
    (go rules)))

(def %mk-member?
  (fn (_ x l)
    (def go
      (fn (self es)
        (if (null? es) #f
          (if (string=? (first es) x) #t (self (rest es))))))
    (go l)))

(def %mk-phony? (fn (_ phony target) (%mk-member? target phony)))

(def %mk-silent?
  (fn (_ target)
    (match
      ((mk-quiet) #t)
      ((eq? %mk-silent (lit all)) #t)
      (#t (%mk-member? target %mk-silent)))))

(def %mk-ends?
  (fn (_ s suf)
    (def ls (byte-len s))
    (def lf (byte-len suf))
    (if (> ls lf) (string=? (substring s (- ls lf) ls) suf) #f)))

; a suffix rule by name: a rule with no prerequisites and a recipe (an
; empty recipe cancels one)
(def %mk-suffix-rule
  (fn (_ rules name)
    (let ((r (%mk-find-rule rules name)))
      (if (null? r) ()
        (if (if (null? (first (rest r))) (pair? (first (rest (rest r)))) #f)
          r
          ())))))

; an implied source is one that exists or has a rule of its own
(def %mk-source?
  (fn (_ rules src)
    (if (file-exists? (mk-path src)) #t
      (pair? (%mk-find-rule rules src)))))

; the suffix rule that makes TARGET, the reading every make shares: a
; double-suffix rule .s1.s2: makes a target ending in .s2 from the stem
; plus .s1, a single-suffix rule .s1: makes any target from the target
; plus .s1, the suffixes those of .SUFFIXES in order; answers (stem
; prereqs recipes) or nil
(def %mk-find-suffix
  (fn (_ rules target)
    (def sufs (mk-suffixes))
    (def double
      (fn (self s2 s1s)
        (if (null? s1s) ()
          (let ((stem (substring target 0
                        (- (byte-len target) (byte-len s2)))))
            (def r (%mk-suffix-rule rules (string-append (first s1s) s2)))
            (def src (string-append stem (first s1s)))
            (if (if (null? r) #f (%mk-source? rules src))
              (list stem (list src) (first (rest (rest r))))
              (self s2 (rest s1s)))))))
    (def doubles
      (fn (self s2s)
        (if (null? s2s) ()
          (let ((hit (if (%mk-ends? target (first s2s))
                       (double (first s2s) sufs)
                       ())))
            (if (null? hit) (self (rest s2s)) hit)))))
    (def singles
      (fn (self s1s)
        (if (null? s1s) ()
          (let ((r (%mk-suffix-rule rules (first s1s))))
            (def src (string-append target (first s1s)))
            (if (if (null? r) #f (%mk-source? rules src))
              (list target (list src) (first (rest (rest r))))
              (self (rest s1s)))))))
    (let ((hit (doubles sufs)))
      (if (null? hit) (singles sufs) hit))))

; the implicit rule for TARGET, a pattern rule before a suffix rule:
; (stem prereqs recipes) or nil
(def %mk-find-implicit
  (fn (_ rules target)
    (let ((pm (%mk-find-pattern rules target)))
      (if (null? pm)
        (%mk-find-suffix rules target)
        (list (first pm)
          (map (fn (_ p) (mk-subst "%" (first pm) p)) (first (rest (rest pm))))
          (first (rest (rest (rest pm)))))))))

; run one recipe line; answers the status
(def %mk-run-line
  (fn (_ line quiet)
    (def silent (if (> (byte-len line) 0) (= (byte-at line 0) 64) #f))
    (def l1 (if silent (substring line 1 (byte-len line)) line))
    (def soft (if (> (byte-len l1) 0) (= (byte-at l1 0) 45) #f))
    (def l2 (if soft (substring l1 1 (byte-len l1)) l1))
    (if (if (mk-dry) #t (if silent #f (not quiet)))
      (display (string-append l2 "\n"))
      ())
    (if (mk-dry) 0
      (let ((full (if (= (byte-len (mk-cwd)) 0) l2
                    (string-append "cd " (string-append (mk-cwd)
                      (string-append " && " l2))))))
        (def st (proc-run (list "/bin/sh" "-c" full)))
        (if (if (if soft #t (mk-ignore)) (> st 0) #f)
          (do (display
                (string-append "make: [ignored] recipe failed: "
                  (string-append l2 "\n")))
              0)
          st)))))

(def %mk-run-recipes
  (fn (self lines vars autos quiet)
    (if (null? lines) 0
      (let ((st (%mk-run-line (mk-expand (first lines) vars autos) quiet)))
        (if (> st 0) st (self (rest lines) vars autos quiet))))))

; build TARGET; answers (built? . status).  VISITING guards cycles.
(def mk-build ())

; build each of TS in turn; answers (built-names . status), stopping at
; the first failure unless -k keeps going
(def %mk-build-list
  (fn (self ts vars rules phony visiting built)
    (if (null? ts) (pair built 0)
      (let ((r (mk-build (first ts) vars rules phony visiting)))
        (match
          ((= (rest r) 0)
            (self (rest ts) vars rules phony visiting
              (if (first r) (pair (first ts) built) built)))
          ((mk-keep)
            (pair (first (self (rest ts) vars rules phony visiting built))
              (rest r)))
          (#t (pair built (rest r))))))))

; the prerequisites newer than the target: every one when it is absent,
; else those remade, absent or with a later mtime
(def %mk-newer
  (fn (_ prereqs built mine)
    (if (null? mine) prereqs
      (filter
        (fn (_ p)
          (if (%mk-member? p built) #t
            (let ((m (file-stat-mtime (mk-path p))))
              (if (null? m) #t (> m mine)))))
        prereqs))))

; the rule to build by, (stem prereqs recipes): the explicit rule's, an
; implicit rule's, or both when the explicit rule has no recipe (the
; implied source joins its prerequisites, as GNU and BSD read it)
(def %mk-rule-of
  (fn (_ explicit implicit)
    (match
      ((null? explicit) implicit)
      ((null? implicit)
        (list "" (first (rest explicit)) (first (rest (rest explicit)))))
      (#t
        (list (first implicit)
          (append (first (rest implicit)) (first (rest explicit)))
          (first (rest (rest implicit))))))))

(set! mk-build
  (fn (_ target vars rules phony visiting)
    (if (%mk-member? target visiting)
      (Err raise (lit make)
        (string-append "make: circular dependency on " target) ())
      (let ((explicit (%mk-find-rule rules target)))
        (def implicit
          (if (if (null? explicit) #t (null? (first (rest (rest explicit)))))
            (%mk-find-implicit rules target)
            ()))
        (def rule (%mk-rule-of explicit implicit))
        (match
          ((pair? rule) (%mk-build-by target rule vars rules phony visiting))
          ((file-exists? (mk-path target)) (pair #f 0))
          (#t
            (pair #f
              (do (display
                    (string-append "make: no rule to make target "
                      (string-append target "\n")))
                  2))))))))

; build TARGET by RULE, (stem prereqs recipes), its prerequisites first
(def %mk-build-by
  (fn (_ target rule vars rules phony visiting)
    (def stem (first rule))
    (def prereqs (first (rest rule)))
    (def pre
      (%mk-build-list prereqs vars rules phony (pair target visiting) ()))
    (if (> (rest pre) 0)
      (do (if (mk-keep)
            (display
              (string-append "make: target "
                (string-append target " not remade because of errors\n")))
            ())
          (pair #f (rest pre)))
      (let ((mine (file-stat-mtime (mk-path target))))
        ; remade when phony, absent, or a prerequisite is newer: one
        ; remade (so FORCE: with no file behind it remakes its
        ; dependents, the idiom every make reads) or with a later mtime
        (def newer (%mk-newer prereqs (first pre) mine))
        (def need
          (match
            ((%mk-phony? phony target) #t)
            ((null? mine) #t)
            (#t (pair? newer))))
        (if (not need)
          (pair #f 0)
          (let ((autos
                  (list
                    (pair "@" target)
                    (pair "<" (if (null? prereqs) "" (first prereqs)))
                    (pair "^" (mk-join prereqs " "))
                    (pair "*" stem)
                    (pair "?" (mk-join newer " ")))))
            (def st
              (%mk-run-recipes (first (rest (rest rule))) vars autos
                (%mk-silent? target)))
            (if (> st 0)
              (do (display
                    (string-append "make: recipe for "
                      (string-append target " failed\n")))
                  (pair #t 2))
              (pair #t 0))))))))

; the first non-dot, non-pattern target is the default goal
(def mk-default-goal
  (fn (_ rules)
    (def go
      (fn (self rs)
        (if (null? rs) ()
          (let ((t (first (first (first rs)))))
            (if (if (> (byte-len t) 0) (= (byte-at t 0) 46) #f)
              (self (rest rs))
              (if (< (mk-find t "%") 0)
                t
                (self (rest rs))))))))
    (go rules)))

(provide mk/run
  mk-build mk-default-goal mk-dry mk-dry! mk-ignore! mk-keep mk-keep!
  mk-quiet mk-quiet! mk-silent! mk-suffixes!)
