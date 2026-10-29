; # x-make -- a make on x-lang
;
; ## mk/cli.x -- the command line
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
;   x -l make -- [-C dir] [-f makefile] [-eikns] [VAR=value]... [target]...
;   x -l make -- --help
;
; The `--` lets make's own options through x.sh's parsing; without it,
; place options after the first target.  Statuses: 0 built or up to
; date, 2 anything failed -- GNU's own reading.

(module mk/cli)
(import mk/expand mk-cwd mk-cwd! mk-find mk-path mk-top-at mk-var-set!)
(import mk/parse mk-parse)
(import mk/prims
  byte-at byte-len file-exists? file-read-all file-write-all reverse
  set-first! string-append string-concat string=? substring sys-environ
  sys-exit)
(import mk/run
  mk-build mk-default-goal mk-dry mk-dry! mk-ignore! mk-keep mk-keep!
  mk-quiet mk-quiet! mk-silent! mk-suffixes!)

; The options, declared once: what the parse accepts, what --help prints and
; what a refusal prints, laid out as busybox lays its help text out.
(def %mk-options
  (Opts declare "make"
    "[-eikns] [-C DIR] [-f FILE] [VAR=VALUE]... [TARGET]..."
    "Bring TARGETs up to date, as a makefile describes them"
    (list
      (Opts arg "-C" "DIR" "Change to DIR before reading the makefile")
      (Opts arg "-f" "FILE" "Read FILE as the makefile")
      (Opts flag "-e" "Let the environment override the makefile's variables")
      (Opts flag "-i" "Ignore a failing command, as a - prefix does")
      (Opts flag "-k" "Keep going past a target that failed")
      (Opts flag "-n" "Print the commands, run none")
      (Opts flag "-s" "Run commands without printing them")
      ; GNU make's and BSD make's -w prints the directory entered and
      ; left; this make never prints one, so -w is taken and does nothing
      (Opts hidden (Opts flag "-w" "Nothing")))))

; a VAR=value operand: NAME then =
(def %mk-assign-op?
  (fn (_ op)
    (def at (mk-find op "="))
    (if (< at 1) #f
      (let ((go (fn (self i)
                  (if (>= i at) #t
                    (let ((b (byte-at op i)))
                      (if (match
                            ((if (>= b 65) (<= b 90) #f) #t)
                            ((if (>= b 97) (<= b 122) #f) #t)
                            ((if (>= b 48) (<= b 57) #f) #t)
                            (#t (= b 95)))
                        (self (+ i 1))
                        #f))))))
        (go 0)))))

; ARGV -> ((cwd makefile dry quiet env ignore keep) (overrides) (targets)),
; or nil when an option make does not take is on the line.  Options may come
; anywhere among the operands, as GNU's make takes them; a -C or -f given
; twice keeps the last.
(def mk-parse-cli
  (fn (_ argv)
    (def o (Opts parse %mk-options argv))
    (def split
      (fn (self ops ovr targets)
        (match
          ((null? ops) (list (reverse ovr) (reverse targets)))
          ((%mk-assign-op? (first ops)) (self (rest ops) (pair (first ops) ovr) targets))
          (#t (self (rest ops) ovr (pair (first ops) targets))))))
    (if (not (null? (Opts unknown o))) ()
      (let ((s (split (Opts operands o) () ())))
        (list (list (Opts value o "-C" "") (Opts value o "-f")
                    (Opts on? o "-n") (Opts on? o "-s")
                    (Opts on? o "-e") (Opts on? o "-i") (Opts on? o "-k"))
              (first s) (first (rest s)))))))

; The line refused: musl getopt's words for the option, as every bundle here
; refuses one, then the usage text, on standard error, and 2 -- make's trouble.
(def %mk-refuse
  (fn (_ tok)
    (do (file-write-all "/dev/stderr"
          (string-concat (list "make: " (%mk-refusal tok) "\n" (Opts usage %mk-options))))
        2)))

; What is wrong with TOK: in a short cluster, read left to right, the first
; letter make does not take is unrecognized, and -C or -f with nothing after
; it requires an argument; a long option is named without its dashes.
(def %mk-refusal
  (fn (_ tok)
    (def end (byte-len tok))
    (def member?
      (fn (self s l) (if (null? l) #f (if (string=? (first l) s) #t (self s (rest l))))))
    (def go
      (fn (self i)
        (let ((opt (string-append "-" (substring tok i (+ i 1)))))
          (match
            ((>= i end) (string-append "unrecognized option: " (substring tok 1 end)))
            ((member? opt (Opts valued %mk-options))
              (string-append "option requires an argument: " (substring tok i (+ i 1))))
            ((member? opt (Opts flags %mk-options)) (self (+ i 1)))
            (#t (string-append "unrecognized option: " (substring tok i (+ i 1))))))))
    (if (if (> end 2) (= (byte-at tok 1) #\-) #f)
      (string-append "unrecognized option: " (substring tok 2 end))
      (go 1))))

; the pure-ish core the specs drive: argv in, output out, status back
(def mk-run
  (fn (_ argv)
    (match
      ((Opts help? %mk-options argv)
        (do (display (Opts usage %mk-options)) 0))
      ((null? (mk-parse-cli argv))
        (%mk-refuse (Opts unknown (Opts parse %mk-options argv))))
      (#t (%mk-run-plan (mk-parse-cli argv))))))

(def %mk-nth
  (fn (self l i) (if (= i 0) (first l) (self (rest l) (- i 1)))))

; the process's environment as ((NAME . VALUE) ...), read and split once:
; the walk over environ costs tens of megabytes a call on an engine
; without automatic collection, and so does a split of every entry.
(def %mk-env-cell (list #f ()))                 ; (read? pairs)

; what the environment never sets: MAKE is this make's own, and SHELL is
; the makefile's or the command line's, the reading GNU make and BSD make
; share (POSIX leaves the shell to the implementation and keeps the
; environment's SHELL out of it)
(def %mk-env-own?
  (fn (_ name) (if (string=? name "MAKE") #t (string=? name "SHELL"))))
(def %mk-environ
  (fn (_)
    (if (first %mk-env-cell) ()
      (do (set-first! (rest %mk-env-cell) (%mk-env-pairs (sys-environ) ()))
          (set-first! %mk-env-cell #t)))
    (first (rest %mk-env-cell))))

(def %mk-env-pairs
  (fn (self es acc)
    (if (null? es) (reverse acc)
      (let ((e (first es)))
        (def at (mk-top-at e 61))
        (self (rest es)
          (if (if (> at 0) (not (%mk-env-own? (substring e 0 at))) #f)
            (pair (pair (substring e 0 at) (substring e (+ at 1) (byte-len e)))
              acc)
            acc))))))

; the environment, every make's reading: a makefile assignment overrides
; it unless -e locks it, and a command-line override, locked first, beats
; both
(def %mk-import-env!
  (fn (_ vars label)
    (def go
      (fn (self ps)
        (if (null? ps) ()
          (do (mk-var-set! vars (first (first ps)) label (rest (first ps)))
              (self (rest ps))))))
    (go (%mk-environ))))

; the run itself, once the line has parsed
(def %mk-run-plan
  (fn (_ plan)
    (def opts (first plan))
    (def ovr (first (rest plan)))
    (def targets (first (rest (rest plan))))
    (mk-cwd! (first opts))
    (mk-dry! (%mk-nth opts 2))
    (mk-quiet! (%mk-nth opts 3))
    (mk-ignore! (%mk-nth opts 5))
    (mk-keep! (%mk-nth opts 6))
    (def mf-name
      (if (null? (first (rest opts)))
        (if (file-exists? (mk-path "Makefile")) "Makefile"
          (if (file-exists? (mk-path "makefile")) "makefile" ()))
        (first (rest opts))))
    (if (null? mf-name)
      (do (file-write-all "/dev/stderr" "make: no makefile found\n")
          2)
      (let ((vars (list ())))
        ; MAKE for recursion, CC and SHELL as GNU make and BSD make
        ; default them (a CC?= in the makefile leaves it; a SHELL= names
        ; the shell the recipes run under); command-line overrides LOCK
        ; theirs
        (mk-var-set! vars "MAKE" (lit rec) "x -l make --")
        (mk-var-set! vars "CC" (lit rec) "cc")
        (mk-var-set! vars "SHELL" (lit rec) "/bin/sh")
        (def lock!
          (fn (self os)
            (if (null? os) ()
              (let ((at (mk-find (first os) "=")))
                (mk-var-set! vars (substring (first os) 0 at)
                  (lit lock)
                  (substring (first os) (+ at 1) (byte-len (first os))))
                (self (rest os))))))
        (lock! ovr)
        (%mk-import-env! vars (if (%mk-nth opts 4) (lit lock) (lit rec)))
        (def parsed (mk-parse (file-read-all (mk-path mf-name)) vars))
        (def rules (first (rest parsed)))
        (def phony (first (rest (rest parsed))))
        (mk-silent! (%mk-nth parsed 3))
        (mk-suffixes! (%mk-nth parsed 4))
        (def goals
          (if (null? targets)
            (let ((d (mk-default-goal rules)))
              (if (null? d)
                (Err raise (lit make) "make: no targets" ())
                (list d)))
            targets))
        ; every goal in turn, stopping at the first that failed unless -k
        ; keeps going; the worst status
        (def run
          (fn (self gs any-built? status)
            (if (null? gs)
              (do (if any-built? ()
                    (if (if (mk-quiet) #t (> status 0)) ()
                      (display "make: nothing to be done\n")))
                  status)
              (let ((r (mk-build (first gs) vars rules phony ())))
                (if (if (> (rest r) 0) (not (mk-keep)) #f)
                  (rest r)
                  (self (rest gs)
                    (if (first r) #t any-built?)
                    (if (> (rest r) status) (rest r) status)))))))
        (run goals #f 0)))))

; Run the operands, (Sys args 'program) past the engine's path, and DO NOT
; RETURN.
(def mk-main
  (fn (_ operands)
    (sys-exit (mk-run operands))))

(provide mk/cli
  mk-main mk-parse-cli mk-run)
