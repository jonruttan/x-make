; # x-make -- a make on x-lang
;
; ## mk/cli.x -- the command line
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
;   x -l make -- [-C dir] [-f makefile] [-ns] [VAR=value]... [target]...
;   x -l make -- --help
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

; The options, declared once: what the parse accepts, what --help prints and
; what a refusal prints, laid out as busybox lays its help text out.
(def %mk-options
  (Opts declare "make"
    "[-ns] [-C DIR] [-f FILE] [VAR=VALUE]... [TARGET]..."
    "Bring TARGETs up to date, as a makefile describes them"
    (list
      (Opts arg "-C" "DIR" "Change to DIR before reading the makefile")
      (Opts arg "-f" "FILE" "Read FILE as the makefile")
      (Opts flag "-n" "Print the commands, run none")
      (Opts flag "-s" "Run commands without printing them"))))

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

; ARGV -> ((cwd makefile dry quiet) (overrides) (targets)), or nil when an
; option make does not take is on the line.  Options may come anywhere among
; the operands, as GNU's make takes them; a -C or -f given twice keeps the
; last.
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
                    (Opts on? o "-n") (Opts on? o "-s"))
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

; the run itself, once the line has parsed
(def %mk-run-plan
  (fn (_ plan)
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
