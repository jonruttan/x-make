; # x-make -- a make on x-lang
;
; ## mk/run.x -- the DAG walk, recipes, the command line
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; The rebuild rule, POSIX's: a target rebuilds when it does not exist
; or any prerequisite's mtime is STRICTLY newer (equal seconds means
; up to date -- mtimes are whole seconds here).  .PHONY targets always
; run.  Recipes run one line at a time through /bin/sh -c, under
; `cd PREFIX &&` when -C gave one; @ silences the echo, - forgives the
; status.  Automatic variables: $@ $< $^ $*.

(def %mk-quiet #f)     ; -s
(def %mk-dry #f)       ; -n: echo recipes, run nothing

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
            (def pc (%mk-find t "%"))
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

(def %mk-phony?
  (fn (_ phony target)
    (def go
      (fn (self ps)
        (if (null? ps) #f
          (if (string=? (first ps) target) #t (self (rest ps))))))
    (go phony)))

(def %mk-newest
  (fn (self ts best)
    (if (null? ts) best
      (let ((m (file-stat-mtime (%mk-path (first ts)))))
        (self (rest ts)
          (if (null? m) best
            (if (null? best) m (if (> m best) m best))))))))

; run one recipe line; answers the status
(def %mk-run-line
  (fn (_ line)
    (def silent (if (> (byte-len line) 0) (= (byte-at line 0) 64) #f))
    (def l1 (if silent (substring line 1 (byte-len line)) line))
    (def soft (if (> (byte-len l1) 0) (= (byte-at l1 0) 45) #f))
    (def l2 (if soft (substring l1 1 (byte-len l1)) l1))
    (if (if %mk-dry #t (if silent #f (not %mk-quiet)))
      (display (string-append l2 "\n"))
      ())
    (if %mk-dry 0
      (let ((full (if (= (byte-len %mk-cwd) 0) l2
                    (string-append "cd " (string-append %mk-cwd
                      (string-append " && " l2))))))
        (def st (proc-run (list "/bin/sh" "-c" full)))
        (if (if soft (> st 0) #f)
          (do (display
                (string-append "make: [ignored] recipe failed: "
                  (string-append l2 "\n")))
              0)
          st)))))

(def %mk-run-recipes
  (fn (self lines vars autos)
    (if (null? lines) 0
      (let ((st (%mk-run-line (%mk-expand (first lines) vars autos))))
        (if (> st 0) st (self (rest lines) vars autos))))))

; build TARGET; answers (built? . status).  VISITING guards cycles.
(def %mk-build ())

(def %mk-build-list
  (fn (self ts vars rules phony visiting)
    (if (null? ts) 0
      (let ((r (%mk-build (first ts) vars rules phony visiting)))
        (if (> (rest r) 0) (rest r)
          (self (rest ts) vars rules phony visiting))))))

(def %mk-member?
  (fn (_ x l)
    (def go
      (fn (self es)
        (if (null? es) #f
          (if (string=? (first es) x) #t (self (rest es))))))
    (go l)))

(set! %mk-build
  (fn (_ target vars rules phony visiting)
    (if (%mk-member? target visiting)
      (Err raise (lit make)
        (string-append "make: circular dependency on " target) ())
      (let ((explicit (%mk-find-rule rules target)))
        (def pm (if (null? explicit) (%mk-find-pattern rules target) ()))
        (def stem (if (null? pm) () (first pm)))
        (def rule (if (null? explicit) (if (null? pm) () (rest pm)) explicit))
        (if (null? rule)
          (if (file-exists? (%mk-path target))
            (pair #f 0)
            (pair #f
              (do (display
                    (string-append "make: no rule to make target "
                      (string-append target "\n")))
                  2)))
          (let ((prereqs
                  (if (null? stem)
                    (first (rest rule))
                    (map (fn (_ p) (%mk-subst "%" stem p))
                      (first (rest rule))))))
            (def pst
              (%mk-build-list prereqs vars rules phony
                (pair target visiting)))
            (if (> pst 0)
              (pair #f pst)
              (let ((mine (file-stat-mtime (%mk-path target))))
                (def need
                  (if (%mk-phony? phony target) #t
                    (if (null? mine) #t
                      (let ((np (%mk-newest prereqs ())))
                        (if (null? np) #f (> np mine))))))
                (if (not need)
                  (pair #f 0)
                  (let ((autos
                          (list
                            (pair "@" target)
                            (pair "<" (if (null? prereqs) ""
                                        (first prereqs)))
                            (pair "^" (%mk-join prereqs " "))
                            (pair "*" (if (null? stem) "" stem)))))
                    (def st
                      (%mk-run-recipes (first (rest (rest rule)))
                        vars autos))
                    (if (> st 0)
                      (do (display
                            (string-append "make: recipe for "
                              (string-append target " failed\n")))
                          (pair #t 2))
                      (pair #t 0))))))))))))

; the first non-dot, non-pattern target is the default goal
(def %mk-default-goal
  (fn (_ rules)
    (def go
      (fn (self rs)
        (if (null? rs) ()
          (let ((t (first (first (first rs)))))
            (if (if (> (byte-len t) 0) (= (byte-at t 0) 46) #f)
              (self (rest rs))
              (if (< (%mk-find t "%") 0)
                t
                (self (rest rs))))))))
    (go rules)))
