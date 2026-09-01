; # x-make -- a make on x-lang
;
; ## mk/cli.x -- the command line
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
;   x -l make -- [-C dir] [-f makefile] [-ns] [VAR=value]... [target]...
;
; The `--` lets make's own -C/-f/-n/-s through x.sh's parsing; without
; it, place options after the first target.  Statuses: 0 built or up to
; date, 2 anything failed -- GNU's own reading.

(def %mk-cli-engine-flag?
  (fn (_ s)
    (if (string=? s "--quiet") #t
      (if (string=? s "--batch") #t
        (if (string=? s "--no-color") #t (string=? s "--verbose"))))))

(def mk-argv
  (fn (_ raw)
    (def ops
      (filter (fn (_ a) (not (%mk-cli-engine-flag? a)))
        (if (pair? raw) (rest raw) ())))
    (if (if (pair? ops) (string=? (first ops) "--") #f)
      (rest ops)
      ops)))

(def %mk-optarg
  (fn (_ op ops)
    (if (> (byte-len op) 2)
      (pair (substring op 2 (byte-len op)) (rest ops))
      (if (null? (rest ops))
        (Err raise (lit make)
          (string-append "make: option needs an argument: " op) ())
        (pair (first (rest ops)) (rest (rest ops)))))))

; a VAR=value operand: NAME then =
(def %mk-assign-op?
  (fn (_ op)
    (def at (%mk-find op "="))
    (if (< at 1) #f
      (let ((go (fn (self i)
                  (if (>= i at) #t
                    (let ((b (byte-at op i)))
                      (if (if (if (>= b 65) (<= b 90) #f) #t
                            (if (if (>= b 97) (<= b 122) #f) #t
                              (if (if (>= b 48) (<= b 57) #f) #t
                                (= b 95))))
                        (self (+ i 1))
                        #f))))))
        (go 0)))))

; ARGV -> ((cwd makefile dry quiet) (overrides) (targets))
(def mk-parse-cli
  (fn (_ operands)
    (def go
      (fn (self ops cwd mf dry quiet ovr targets)
        (if (null? ops)
          (list (list cwd mf dry quiet) (reverse ovr) (reverse targets))
          (let ((op (first ops)))
            (if (if (>= (byte-len op) 2) (= (byte-at op 0) 45) #f)
              (let ((b1 (byte-at op 1)))
                (if (= b1 67)                              ; C
                  (let ((r (%mk-optarg op ops)))
                    (self (rest r) (first r) mf dry quiet ovr targets))
                  (if (= b1 102)                           ; f
                    (let ((r (%mk-optarg op ops)))
                      (self (rest r) cwd (first r) dry quiet ovr targets))
                    (if (= b1 110)                         ; n
                      (self (rest ops) cwd mf #t quiet ovr targets)
                      (if (= b1 115)                       ; s
                        (self (rest ops) cwd mf dry #t ovr targets)
                        (Err raise (lit make)
                          (string-append "make: unknown option: " op)
                          ()))))))
              (if (%mk-assign-op? op)
                (self (rest ops) cwd mf dry quiet (pair op ovr) targets)
                (self (rest ops) cwd mf dry quiet ovr
                  (pair op targets))))))))
    (go operands "" () #f #f () ())))

; the pure-ish core the specs drive: argv in, output out, status back
(def mk-run
  (fn (_ argv)
    (def plan (mk-parse-cli argv))
    (def opts (first plan))
    (def ovr (first (rest plan)))
    (def targets (first (rest (rest plan))))
    (set! %mk-cwd (first opts))
    (set! %mk-dry (first (rest (rest opts))))
    (set! %mk-quiet (first (rest (rest (rest opts)))))
    (def mf-name
      (if (null? (first (rest opts)))
        (if (file-exists? (%mk-path "Makefile")) "Makefile"
          (if (file-exists? (%mk-path "makefile")) "makefile" ()))
        (first (rest opts))))
    (if (null? mf-name)
      (do (file-write-all "/dev/stderr" "make: no makefile found\n")
          2)
      (let ((vars (list ())))
        ; MAKE for recursion; command-line overrides LOCK theirs
        (%mk-var-set! vars "MAKE" (lit rec) "x -l make --")
        (def lock!
          (fn (self os)
            (if (null? os) ()
              (let ((at (%mk-find (first os) "=")))
                (%mk-var-set! vars (substring (first os) 0 at)
                  (lit lock)
                  (substring (first os) (+ at 1) (byte-len (first os))))
                (self (rest os))))))
        (lock! ovr)
        (def parsed (mk-parse (file-read-all (%mk-path mf-name)) vars))
        (def rules (first (rest parsed)))
        (def phony (first (rest (rest parsed))))
        (def goals
          (if (null? targets)
            (let ((d (%mk-default-goal rules)))
              (if (null? d)
                (Err raise (lit make) "make: no targets" ())
                (list d)))
            targets))
        (def run
          (fn (self gs any-built?)
            (if (null? gs)
              (do (if any-built? ()
                    (if %mk-quiet ()
                      (display "make: nothing to be done\n")))
                  0)
              (let ((r (%mk-build (first gs) vars rules phony ())))
                (if (> (rest r) 0)
                  (rest r)
                  (self (rest gs)
                    (if (first r) #t any-built?)))))))
        (run goals #f)))))

; Run the command line and DO NOT RETURN.
(def mk-main
  (fn (_ raw-args)
    (sys-exit (mk-run (mk-argv raw-args)))))
