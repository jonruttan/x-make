# x-make card

## Run

```sh
x -l make -- [-C DIR] [-f FILE] [-eikns] [VAR=VALUE]... [TARGET]...
x -l make -- -C tests/card -> hello world
x -l make -- -f tests/card/Makefile hello -> hello world
x -l make -- -C tests/card NAME=there -> hello there
x -l make -- -C tests/card -n list -> echo one
x -l make -- -C tests/card -s list -> one
x -l make -- -C tests/card nope -> make: no rule to make target nope
x -l make -- -C tests/card nope >/dev/null; echo $? -> 2
```

```make
NAME = world

all: hello

hello:
	@echo hello $(NAME)             # -> hello world

list:
	echo one
```

| Operand     | Meaning                                                   |
|-------------|-----------------------------------------------------------|
| `--`        | ends x's own options; make's options follow it            |
| `-C DIR`    | read the makefile in DIR and run the recipes there        |
| `-f FILE`   | read FILE; without it, `Makefile`                         |
| `-n`        | print the commands, run none                              |
| `-s`        | run the commands without printing them                    |
| `-k`        | keep going past a target that failed                      |
| `-i`        | ignore a failing command, as a `-` prefix does            |
| `-e`        | the environment overrides the makefile's variables        |
| `VAR=VALUE` | set VAR over the makefile; the makefile cannot change it  |
| `TARGET...` | what to bring up to date; without one, the first target   |

| Status | Means                                     |
|--------|-------------------------------------------|
| `0`    | every target is built or up to date       |
| `2`    | a recipe failed, or a target has no rule  |

## Makefile

| Line                    | Is                                              |
|-------------------------|-------------------------------------------------|
| `TARGET...: PREREQ...`  | a rule: what is made, and from what             |
| a line led by a tab     | a recipe line of the rule above, run by a shell |
| `NAME = VALUE`          | an assignment                                   |
| `# TEXT`                | a comment, to the end of the line               |
| `include FILE...`       | the lines of FILE, read here                    |
| `-include FILE...`      | the same, and no trouble when FILE is missing   |
| `ifeq` ... `endif`      | lines read only when the test holds             |
| a `\` ending a line     | the next line continues this one                |

```make
# the first rule is the default goal
all: one two
	@echo all is made

one two:
	@echo making $@
```

```output
making one
making two
all is made
```

## Variables

### Assignment

| Form            | Sets NAME to                                      |
|-----------------|---------------------------------------------------|
| `NAME = TEXT`   | TEXT, expanded each time NAME is used             |
| `NAME := TEXT`  | TEXT, expanded now                                |
| `NAME ?= TEXT`  | TEXT, only when NAME has no value yet             |
| `NAME += TEXT`  | its value, a space, TEXT                          |
| `NAME != CMD`   | what the shell command prints, newlines as spaces |

```make
LATE = $(WHO)
NOW := $(WHO)
WHO = world

FLAGS = -O2
FLAGS += -g
FLAGS ?= -O0
DAY != echo today

all:
	@echo "late=$(LATE) now=$(NOW)" # -> late=world now=
	@echo $(FLAGS)                  # -> -O2 -g
	@echo $(DAY)                    # -> today
```

### Reference

| Form                | Gives                                           |
|---------------------|-------------------------------------------------|
| `$(NAME)` `${NAME}` | the value of NAME; empty when it has none       |
| `$X`                | the value of the one-letter name X              |
| `$$`                | a dollar, for the shell                         |
| `$(NAME:.c=.o)`     | the value, each word's `.c` ending made `.o`    |
| `$($(NAME))`        | the value of the name that NAME holds           |

```make
SRCS = main.c util.c
PICK = SRCS
B = one letter

all:
	@echo $(SRCS:.c=.o)             # -> main.o util.o
	@echo $($(PICK))                # -> main.c util.c
	@echo ${B}, $B                  # -> one letter, one letter
	@echo "[$(NONE)]"               # -> []
	@n=3; echo $$n                  # -> 3
```

### Where a value comes from

| Source                  | Wins over                                     |
|-------------------------|-----------------------------------------------|
| `VAR=VALUE` on the line | everything; the makefile cannot change it     |
| the makefile            | the environment                               |
| the environment         | nothing, unless `-e` puts it over the makefile |
| built in: `CC`          | `cc`, until something sets it                 |
| built in: `SHELL`       | `/bin/sh`; the environment's is never read    |
| built in: `MAKE`        | this make, for a recipe that runs make again  |

### Automatic

| Name | In a recipe, is                                         |
|------|---------------------------------------------------------|
| `$@` | the target                                              |
| `$<` | the first prerequisite                                  |
| `$^` | every prerequisite                                      |
| `$?` | the prerequisites newer than the target                 |
| `$*` | the stem: what `%` matched, or the name less its suffix |

```make
all: one two
	@echo $@ from $^                # -> all from one two
	@echo first $<                  # -> first one

one two:
```

## Rules

| Rule                  | Makes                                            |
|-----------------------|--------------------------------------------------|
| `a: b c`              | `a`, after `b` and `c`, when either is newer     |
| `a b: c`              | `a` and `b`, each by the same recipe             |
| `%.o: %.c`            | any `NAME.o` from its `NAME.c`: a pattern rule   |
| `.c.o:`               | the same, as a suffix rule over `.SUFFIXES`      |
| `.c:`                 | `NAME` from `NAME.c`                             |
| `$(OBJS): %.o: %.c`   | only the targets named, each by the pattern      |
| `a: b`, no recipe     | `a` by the implicit rule that fits, `b` added    |

| Target        | Says                                                     |
|---------------|----------------------------------------------------------|
| `.PHONY: T`   | T is no file: its recipe runs every time                 |
| `.SILENT: T`  | T's recipe is not printed; with no T, no recipe is       |
| `.SUFFIXES:`  | the suffixes that suffix rules are read over             |
| `FORCE:`      | a target with no file and no recipe: what needs it is remade |

### A pattern rule

```make
all: a.o b.o

%.o: %.c
	@echo compile $< to $@, stem $*
	@touch $@

a.c b.c:
	@touch $@
```

```output
compile a.c to a.o, stem a
compile b.c to b.o, stem b
```

### A suffix rule

```make
.SUFFIXES: .txt .out

all: notes.out

.txt.out:
	@echo $< to $@                  # -> notes.txt to notes.out

notes.txt:
	@touch $@
```

### A static pattern rule

```make
OBJS = a.o b.o

all: $(OBJS) c.o

$(OBJS): %.o: %.c
	@echo static $@

%.o: %.c
	@echo pattern $@

a.c b.c c.c:
	@touch $@
```

```output
static a.o
static b.o
pattern c.o
```

### What is remade

```make
all: out kept kept
	@echo all, after both

# out has no file yet, so it is made; made, it remakes what needs it
out:
	@echo out is made
	@touch out

# kept is asked for twice, and is made once
kept:
	@echo kept is made once
	@touch kept
```

```output
out is made
kept is made once
all, after both
```

## Recipes

| Line           | Does                                                  |
|----------------|-------------------------------------------------------|
| `CMD`          | prints CMD, then runs it                              |
| `@CMD`         | runs it without printing it                           |
| `-CMD`         | runs it, and goes on when it fails                    |
| `@-CMD`        | both                                                  |
| each line      | has a shell of its own: a `cd` ends with its line     |
| `A; B`         | one shell for both                                    |
| a `\` ending   | the next line is part of this command                 |
| `$$`           | a `$` for the shell: `$$HOME`, `$$(date)`, `$$x`      |

```make
all:
	echo shown
	@echo quiet
	@-false
	@echo still here
	@cd /; pwd
	@x=1; echo $$x
	@echo one \
	  two
```

```output
echo shown
shown
quiet
make: [ignored] recipe failed: false
still here
/
1
one two
```

## Functions

| Function                    | Gives                                       |
|-----------------------------|---------------------------------------------|
| `$(subst FROM,TO,TEXT)`     | TEXT, every FROM made TO                    |
| `$(patsubst PAT,TO,TEXT)`   | each word that fits PAT made TO; `%` the stem |
| `$(findstring S,TEXT)`      | S when TEXT holds it, else nothing          |
| `$(strip TEXT)`             | TEXT, its runs of blanks one space each     |
| `$(sort TEXT)`              | the words in order, each once               |
| `$(dir NAMES)`              | each name's directory, `./` when it has none |
| `$(notdir NAMES)`           | each name less its directory                |
| `$(basename NAMES)`         | each name less its suffix                   |
| `$(wildcard GLOB...)`       | the files that match, sorted                |
| `$(if COND,THEN,ELSE)`      | THEN when COND is not empty, else ELSE      |
| `$(shell CMD)`              | what CMD prints, newlines as spaces         |

```make
SRCS = lib/a.c lib/b.c main.c

all:
	@echo $(notdir $(SRCS))             # -> a.c b.c main.c
	@echo $(dir $(SRCS))                # -> lib/ lib/ ./
	@echo $(basename $(SRCS))           # -> lib/a lib/b main
	@echo $(patsubst %.c,%.o,$(SRCS))   # -> lib/a.o lib/b.o main.o
	@echo $(subst lib/,src/,$(SRCS))    # -> src/a.c src/b.c main.c
	@echo $(findstring main,$(SRCS))    # -> main
	@echo "[$(strip   a   b  )]"        # -> [a b]
	@echo $(sort c a b a)               # -> a b c
	@echo $(if $(DEBUG),debug,release)  # -> release
	@echo $(shell echo from a shell)    # -> from a shell
	@echo "[$(wildcard *.nothing)]"     # -> []
```

## Conditionals

| Line                 | Reads what follows when                        |
|----------------------|------------------------------------------------|
| `ifeq (A,B)`         | A and B, expanded, are the same text           |
| `ifneq (A,B)`        | they differ                                    |
| `ifdef NAME`         | NAME has a value that is not empty             |
| `ifndef NAME`        | it has none                                    |
| `else`               | the test above did not hold                    |
| `else ifeq (A,B)`    | it did not, and this one does                  |
| `endif`              | ends the conditional                           |

```make
MODE = fast

ifeq ($(MODE),fast)
FLAGS = -O2
else ifeq ($(MODE),small)
FLAGS = -Os
else
FLAGS = -g
endif

ifndef DEBUG
FLAGS += -DNDEBUG
endif

all:
	@echo $(FLAGS)                  # -> -O2 -DNDEBUG
```

## Differs

| Here                                    | In GNU make                        |
|-----------------------------------------|------------------------------------|
| `-C` prefixes paths, runs `cd DIR &&`   | changes directory                  |
| `-w` is taken and does nothing          | prints the directory               |
| times are compared to the whole second  | to the nanosecond                  |
| only `CC` has a default                 | `CXX`, `AR`, `RM` and more do      |
| `define`, `export` are not read         | read                               |
| `VPATH`, `-j`, `::` rules are not built | built                              |
| `-@CMD` runs `@CMD`                     | the prefixes in either order       |

## More

| Where                           | What                                |
|---------------------------------|-------------------------------------|
| `README.md`                     | what is built, and what is not      |
| `tests/specs/02-build.spec.md`  | one case a behaviour                |
| `x -l make -- --help`           | the options                         |
| `make card`                     | runs every makefile on this page    |
