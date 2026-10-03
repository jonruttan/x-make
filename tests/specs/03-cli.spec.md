# @weight 1

The command line, through one Opts declaration: `--help` first prints the help
text on stdout, and 0; an option make does not take is refused in musl
getopt's words, as every bundle here refuses one, then the usage text, on
stderr, and 2.  Options may come anywhere among the operands.

## help

### --help prints the help text on stdout, and 0

```make
(display (mk-run (list "--help")))
```
---
```output
Usage: make [-ns] [-C DIR] [-f FILE] [VAR=VALUE]... [TARGET]...

Bring TARGETs up to date, as a makefile describes them

	-C DIR	Change to DIR before reading the makefile
	-f FILE	Read FILE as the makefile
	-n	Print the commands, run none
	-s	Run commands without printing them
0
```

## refusals

### the words: a letter, a cluster, a long option, a value option given nothing

```make
(display (list (%mk-refusal "-Q") (%mk-refusal "-nQ") (%mk-refusal "--nope") (%mk-refusal "-f") (%mk-refusal "-sC")))
```
---
    (unrecognized option: Q unrecognized option: Q unrecognized option: nope option requires an argument: f option requires an argument: C)

### a refused line runs nothing and answers 2

```make
(display (list (mk-run (list "-Q")) (mk-run (list "all" "-f")) (mk-parse-cli (list "-Q"))))
```
---
    (2 2 ())

## the parse

### options anywhere among the operands; VAR=value apart from the targets; the last -C wins

```make
(display (mk-parse-cli (list "a" "-n" "X=1" "-C" "/tmp" "b" "-s" "-C/var" "-fmk")))
```
---
    ((/var mk #t #t) (X=1) (a b))
