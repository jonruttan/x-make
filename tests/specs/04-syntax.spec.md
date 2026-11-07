# @weight 1

## mk/syntax -- the make highlighting grammar

The bundle's lang.xon declares a grammar, `make`, that x/tool/syntax colours
makefiles with. Its module, `mk/syntax`, imports only x-lang libraries and
registers the grammar as it loads.

The cases share one process, and a registered grammar stays registered, so
the catalogue's case comes first: it finds the grammar through lang.xon,
before anything has imported the module.

### the catalogue finds make by name, by suffix, by #! and by modeline

The langs directory holds this bundle, linked as `make`. The row comes from
lang.xon, its module not loaded until a file asks for the grammar, and the
grammar takes lang.xon's suffixes, names and interpreters.

```make
(do (import x/sys/posix) (import x/sys/file) (import x/tool/syntax)
    (def root (Str8 replace "/mk/syntax.x" "" (%module-resolve-file "mk/syntax.x")))
    (def tmp (File temp "/tmp/x-make-spec-langs-"))
    (File close (first tmp))
    (def d (rest tmp))
    (File unlink d)
    (File mkdir d)
    (File symlink root (Str8 append d "/make"))
    (def was (Sys getenv "X_LANG_DIR"))
    (Sys setenv "X_LANG_DIR" d)
    (Syntax forget!)
    (def row (List find (fn (_ r) (eq? (first r) (lit make))) (Syntax catalogue)))
    (def name (fn (_ path . text)
      (let ((g (apply Syntax (pair (lit for-file) (pair path text))))) (if (null? g) () (g name)))))
    (def seen
      (list (List ref 1 row)
            (name "src/Makefile") (name "GNUmakefile") (name "rules.mk")
            (name "build" "#!/usr/bin/make -f\nall:\n")
            (name "rules" "all:\n# vi: set ft=make:\n")
            (name "Makefile.txt")
            (let ((g (Syntax named (lit make)))) (list (g files) (g names) (g interpreters)))))
    (File unlink (Str8 append d "/make"))
    (File rmdir d)
    (Sys setenv "X_LANG_DIR" (if (null? was) "" was))
    (Syntax forget!)
    seen)
```
---
    ('mk/syntax 'make 'make 'make 'make 'make () ((".mk" ".mak") ("Makefile" "makefile" "GNUmakefile" "BSDmakefile") ("make")))

### a makefile's spans: comments, expansions, directives and operators

```make
(do (import x/tool/syntax) (import mk/syntax)
    ((Syntax named (lit make)) spans
      "# build\nCC ?= cc\nOBJ = $(patsubst %.c,%.o,$(SRC))\n.PHONY: all\nall: $(OBJ) | dir\n\t$(CC) -o $@ $^ \\\n\t  && echo $$HOME\nifeq ($(OS),x)\n-include rules.mk\nendif\n"))
```
---
    ((0 7 'comment) (11 2 'operator) (21 1 'operator) (23 26 'name) (50 6 'constant) (56 1 'operator) (62 3 'class) (65 1 'operator) (67 6 'name) (74 1 'operator) (81 5 'name) (90 2 'name) (93 2 'name) (96 2 'escape) (109 2 'name) (116 4 'keyword) (122 5 'name) (131 8 'keyword) (149 5 'keyword))

### a target colours apart from its colons

A word then one to three colons is a target, the colons the rule's
operator; a word then := or ::= is a macro's name, left plain.  Each token
is lexical, so of two targets only the one touching the colon colours.

```make
(do (import x/tool/syntax) (import mk/syntax)
    ((Syntax named (lit make)) spans "a:=b\nx y.o: z\n%.o:: %.c\n"))
```
---
    ((1 2 'operator) (7 3 'class) (10 1 'operator) (14 3 'class) (17 2 'operator))

### an expansion left open runs to the end

```make
(do (import x/tool/syntax) (import mk/syntax)
    (List map (fn (_ s) ((Syntax named (lit make)) spans s))
      (list "X = $(a" "X = ${a $(b)" "X = $")))
```
---
    (((2 1 'operator) (4 3 'name)) ((2 1 'operator) (4 8 'name)) ((2 1 'operator)))

### a window reads from the line above it that starts a rule

Spans walk back from a window's first line to one that is neither indented
nor continued, so an expansion opened above colours the window's start.

```make
(do (import x/tool/syntax) (import mk/syntax)
    ((Syntax named (lit make)) spans "X = $(a \\\n  b\n  c) d\n" 14 6))
```
---
    ((14 4 'name))
