# @weight 2

The runner against real fixtures: mk-run ARGV, output on stdout, the
status as the value -- a case's last output line is the status.

## fixture

### the scratch tree

```make
(do (proc-run (list "/bin/sh" "-c" "rm -rf /tmp/x-make-spec && mkdir -p /tmp/x-make-spec")) (file-write-all "/tmp/x-make-spec/Makefile" "X = world\nall: out.txt\n\t@echo hello $(X)\nout.txt:\n\t@printf made > out.txt\n%.o: %.c\n\t@cp $< $@\nlog: stamp\nstamp: dep\n\t@printf run >> log.txt\n\t@printf s > stamp\n.PHONY: all log\n") (file-write-all "/tmp/x-make-spec/a.c" "src") (file-write-all "/tmp/x-make-spec/b.c" "brc") (file-write-all "/tmp/x-make-spec/dep" "d") (display "made"))
```
---
    made

## the walk

### the default goal builds its prerequisite then runs

```make
(display (mk-run (list "-C" "/tmp/x-make-spec")))
```
---
```output
hello world
0
```

### a command-line override wins and locks

```make
(display (mk-run (list "-C" "/tmp/x-make-spec" "X=cli")))
```
---
```output
hello cli
0
```

### a pattern rule fires with $< and $@

```make
(do (mk-run (list "-C" "/tmp/x-make-spec" "a.o")) (display (file-read-all "/tmp/x-make-spec/a.o")))
```
---
    src

### an up-to-date pattern target does not rerun

```make
(display (mk-run (list "-C" "/tmp/x-make-spec" "a.o")))
```
---
```output
make: nothing to be done
0
```

### -n prints the recipe and touches nothing

```make
(do (display (mk-run (list "-C" "/tmp/x-make-spec" "-n" "b.o"))) (newline) (display (if (file-exists? "/tmp/x-make-spec/b.o") "exists" "absent")))
```
---
```output
cp b.c b.o
0
absent
```

### a stale target rebuilds; a fresh one does not

```make
(do (mk-run (list "-C" "/tmp/x-make-spec" "stamp")) (mk-run (list "-C" "/tmp/x-make-spec" "stamp")) (proc-run (list "/bin/sh" "-c" "touch -t 200001010000 /tmp/x-make-spec/stamp")) (mk-run (list "-C" "/tmp/x-make-spec" "stamp")) (display (file-read-all "/tmp/x-make-spec/log.txt")))
```
---
    runrun

### a missing rule is loud and status 2

```make
(display (mk-run (list "-C" "/tmp/x-make-spec" "nope.xyz")))
```
---
```output
make: no rule to make target nope.xyz
2
```

### a failing recipe is loud and status 2

```make
(do (file-write-all "/tmp/x-make-spec/Makefile.bad" "bad:\n\t@false\n") (display (mk-run (list "-C" "/tmp/x-make-spec" "-f" "Makefile.bad" "bad"))))
```
---
```output
make: recipe for bad failed
2
```

## conditionals, include, the functions in anger

### ifeq picks by an override

```make
(do (file-write-all "/tmp/x-make-spec/Makefile.cond" "ifeq ($(X),a)\nY = one\nelse\nY = two\nendif\nshow:\n\t@echo $(Y)\n") (display (mk-run (list "-C" "/tmp/x-make-spec" "-f" "Makefile.cond" "X=a" "show"))) (newline) (display (mk-run (list "-C" "/tmp/x-make-spec" "-f" "Makefile.cond" "X=b" "show"))))
```
---
```output
one
0
two
0
```

### include splices; wildcard globs sorted

```make
(do (file-write-all "/tmp/x-make-spec/inc.mk" "Z = zed\n") (file-write-all "/tmp/x-make-spec/Makefile.inc" "include inc.mk\nL = $(wildcard *.c)\nshow:\n\t@echo $(Z): $(L)\n") (display (mk-run (list "-C" "/tmp/x-make-spec" "-f" "Makefile.inc" "show"))))
```
---
```output
zed: a.c b.c
0
```

### cleanup

```make
(do (proc-run (list "/bin/sh" "-c" "rm -rf /tmp/x-make-spec")) (display "clean"))
```
---
    clean
