# @weight 2

The runner against real fixtures: mk-run ARGV, output on stdout, the
status as the value -- a case's last output line is the status.

## fixture

### the scratch tree, and a variable in the environment (read once a process, so before any run)

```make
(do (Sys setenv "XMKE" "env") (proc-run (list "/bin/sh" "-c" "rm -rf /tmp/x-make-spec && mkdir -p /tmp/x-make-spec")) (file-write-all "/tmp/x-make-spec/Makefile" "X = world\nall: out.txt\n\t@echo hello $(X)\nout.txt:\n\t@printf made > out.txt\n%.o: %.c\n\t@cp $< $@\nlog: stamp\nstamp: dep\n\t@printf run >> log.txt\n\t@printf s > stamp\n.PHONY: all log\n") (file-write-all "/tmp/x-make-spec/a.c" "src") (file-write-all "/tmp/x-make-spec/b.c" "brc") (file-write-all "/tmp/x-make-spec/dep" "d") (display "made"))
```
---
    made

### a shell that names itself, and a SHELL in the environment no make reads (set before any run, as the environment is read once)

```make
(do (Sys setenv "SHELL" "/nonexistent/sh") (file-write-all "/tmp/x-make-spec/namesh" "#!/bin/sh\necho \"namesh: $2\"\n") (proc-run (list "/bin/sh" "-c" "chmod +x /tmp/x-make-spec/namesh")) (display "ready"))
```
---
    ready

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

### a backslash-newline joins lines with one space; a doubled backslash does not

```make
(do (file-write-all "/tmp/x-make-spec/Makefile.cont" "W = one \\\n    two \\\n  three\nV = back\\\\\nshow:\n\t@echo [$(W)] [$(V)]\n") (display (mk-run (list "-C" "/tmp/x-make-spec" "-f" "Makefile.cont" "show"))))
```
---
```output
[one two three] [back\]
0
```

## the readings every make shares

### CC is cc unless the makefile or the command line says otherwise; ?= leaves it

```make
(do (file-write-all "/tmp/x-make-spec/Makefile.cc" "CC?=gcc\nshow:\n\t@echo $(CC)\n") (display (mk-run (list "-C" "/tmp/x-make-spec" "-f" "Makefile.cc" "show"))) (newline) (display (mk-run (list "-C" "/tmp/x-make-spec" "-f" "Makefile.cc" "CC=clang" "show"))))
```
---
```output
cc
0
clang
0
```

### a prerequisite that was remade remakes its dependent: FORCE, with no file behind it

```make
(do (file-write-all "/tmp/x-make-spec/Makefile.force" "stamp: FORCE\n\t@echo remade\nFORCE:\n") (display (mk-run (list "-C" "/tmp/x-make-spec" "-f" "Makefile.force" "stamp"))))
```
---
```output
remade
0
```

### a continuation outside a recipe condenses the whitespace around it; in a recipe it stands

```make
(do (file-write-all "/tmp/x-make-spec/Makefile.cont2" "V = a \\\n\t\tb \\\n\t\tc\nshow:\n\t@echo \"[$(V)]\"\n\t@printf '%s\\n' 'd \\\n\t   e'\n") (display (mk-run (list "-C" "/tmp/x-make-spec" "-f" "Makefile.cont2" "show"))))
```
---
```output
[a b c]
d \
   e
0
```

### a suffix rule makes the target from the stem plus a source suffix; an explicit rule with no recipe adds its prerequisites; $? names the newer ones

```make
(do (file-write-all "/tmp/x-make-spec/Makefile.suf" ".SUFFIXES:\n.SUFFIXES: .o .c\n.c.o:\n\t@cp $< $@\n\t@echo $* [$<] [$?]\ns.o: s.h\n") (file-write-all "/tmp/x-make-spec/s.c" "src2") (file-write-all "/tmp/x-make-spec/s.h" "hdr") (display (mk-run (list "-C" "/tmp/x-make-spec" "-f" "Makefile.suf" "s.o"))) (newline) (proc-run (list "/bin/sh" "-c" "touch -t 200001010000 /tmp/x-make-spec/s.o /tmp/x-make-spec/s.h")) (display (mk-run (list "-C" "/tmp/x-make-spec" "-f" "Makefile.suf" "s.o"))) (newline) (display (file-read-all "/tmp/x-make-spec/s.o")))
```
---
```output
s [s.c] [s.c s.h]
0
s [s.c] [s.c]
0
src2
```

### a single-suffix rule makes a target from the target plus the suffix

```make
(do (file-write-all "/tmp/x-make-spec/Makefile.single" ".sh:\n\t@cp $< $@\n") (file-write-all "/tmp/x-make-spec/tool.sh" "#!/bin/sh\n") (display (mk-run (list "-C" "/tmp/x-make-spec" "-f" "Makefile.single" "tool"))) (newline) (display (file-read-all "/tmp/x-make-spec/tool")))
```
---
```output
0
#!/bin/sh
```

### != assigns a command's output, its newlines spaces

```make
(do (file-write-all "/tmp/x-make-spec/Makefile.bang" "V != printf 'a\\nb\\n'\nshow:\n\t@echo [$(V)]\n") (display (mk-run (list "-C" "/tmp/x-make-spec" "-f" "Makefile.bang" "show"))))
```
---
```output
[a b]
0
```

### .SILENT silences its targets' recipes, or every recipe when it names none

```make
(do (file-write-all "/tmp/x-make-spec/Makefile.silent" ".SILENT: hush\nhush:\n\techo quiet\nloud:\n\techo loud\n") (file-write-all "/tmp/x-make-spec/Makefile.silent2" ".SILENT:\nall:\n\techo all\n") (display (mk-run (list "-C" "/tmp/x-make-spec" "-f" "Makefile.silent" "hush" "loud"))) (newline) (display (mk-run (list "-C" "/tmp/x-make-spec" "-f" "Makefile.silent2"))))
```
---
```output
quiet
echo loud
loud
0
all
0
```

### -k keeps going past a failed target; without it the first failure ends the run

```make
(do (file-write-all "/tmp/x-make-spec/Makefile.keep" "all: bad good\nbad:\n\t@false\ngood:\n\t@echo good\n") (display (mk-run (list "-C" "/tmp/x-make-spec" "-f" "Makefile.keep" "-k" "all"))) (newline) (display (mk-run (list "-C" "/tmp/x-make-spec" "-f" "Makefile.keep" "all"))))
```
---
```output
make: recipe for bad failed
good
make: target all not remade because of errors
2
make: recipe for bad failed
2
```

### -i forgives every failing command, as a - prefix does

```make
(display (mk-run (list "-C" "/tmp/x-make-spec" "-f" "Makefile.keep" "-i" "bad")))
```
---
```output
make: [ignored] recipe failed: false
0
```

### the environment is a default the makefile overrides; -e lets it override the makefile; the command line beats both

```make
(do (file-write-all "/tmp/x-make-spec/Makefile.env" "XMKE = file\nshow:\n\t@echo $(XMKE)\n") (file-write-all "/tmp/x-make-spec/Makefile.env2" "show:\n\t@echo $(XMKE)\n") (display (mk-run (list "-C" "/tmp/x-make-spec" "-f" "Makefile.env2" "show"))) (newline) (display (mk-run (list "-C" "/tmp/x-make-spec" "-f" "Makefile.env" "show"))) (newline) (display (mk-run (list "-C" "/tmp/x-make-spec" "-f" "Makefile.env" "-e" "show"))) (newline) (display (mk-run (list "-C" "/tmp/x-make-spec" "-f" "Makefile.env" "-e" "XMKE=cli" "show"))))
```
---
```output
env
0
file
0
env
0
cli
0
```

### recipes run under the makefile's SHELL, the command line's over it; the environment's is never read

```make
(do (file-write-all "/tmp/x-make-spec/Makefile.shell" "SHELL = /tmp/x-make-spec/namesh\nshow:\n\t@echo hi\n") (file-write-all "/tmp/x-make-spec/Makefile.noshell" "show:\n\t@echo $(SHELL)\n") (display (mk-run (list "-f" "/tmp/x-make-spec/Makefile.shell" "show"))) (newline) (display (mk-run (list "-f" "/tmp/x-make-spec/Makefile.noshell" "SHELL=/tmp/x-make-spec/namesh" "show"))) (newline) (display (mk-run (list "-f" "/tmp/x-make-spec/Makefile.noshell" "show"))))
```
---
```output
namesh: echo hi
0
namesh: echo /tmp/x-make-spec/namesh
0
/bin/sh
0
```

## the walk's footprint

### a sweep a visit: forty targets remade leave the heap where one did

```make
(do (proc-run (list "/bin/sh" "-c" "{ printf 'all:'; i=0; while [ $i -lt 40 ]; do printf ' t%s' $i; i=$((i+1)); done; printf '\\n'; i=0; while [ $i -lt 40 ]; do printf 't%s:\\n\\t@:\\n' $i; i=$((i+1)); done; } > /tmp/x-make-spec/Makefile.many")) (Heap collect) (let ((c0 (Heap count))) (mk-run (list "-f" "/tmp/x-make-spec/Makefile.many" "t0")) (let ((c1 (Heap count))) (mk-run (list "-f" "/tmp/x-make-spec/Makefile.many" "all")) (let ((c41 (Heap count))) (display (if (< (- c41 c1) (- c1 c0)) "bounded" (list c0 c1 c41)))))))
```
---
    bounded

### cleanup

```make
(do (proc-run (list "/bin/sh" "-c" "rm -rf /tmp/x-make-spec")) (display "clean"))
```
---
    clean
