# x-make

A make on x-lang -- the fourth and last tool of the self-hosting arc's
core set (awk, grep, sed, make).  Deliberately SELF-CONTAINED: make is
the bootstrap's root tool, so this bundle requires no other lang.

The scope is the measured one: the GNU subset x-lang's own Makefiles
use (see `docs/bootstrap-closure.md` for the measurement method).
Working: rules with prerequisites and tab recipes; `=`, `:=`, `?=`,
`+=`; `$(VAR)`, `$X`, `$$`, computed names; the functions `shell`
`wildcard` `findstring` `if` `subst` `patsubst` `basename` `dir`
`notdir` `strip`; `ifeq`/`ifneq`/`ifdef`/`ifndef`/`else`/`endif`;
`include`/`-include`; pattern rules (`%.o: %.c`) with `$@ $< $^ $*`;
`.PHONY`; mtime-driven rebuilds (whole-second granularity); `@` and
`-` recipe prefixes; `-C`, `-f`, `-n`, `-s`, command-line `VAR=value`
overrides (which lock); statuses 0/2.  There is NO chdir anywhere:
`-C` prefixes paths and runs recipes under `cd DIR &&`.

Not built, loudly absent rather than wrong: `$(MAKEFILE_LIST)` and the
other automatic variables beyond the four, suffix rules, `VPATH`,
parallel `-j`, `define`, `export`, double-colon rules.

Paired with x-lang v0.9.0 (`lang.xon` is the checkable row).

## Try it

    make install        # into the x on PATH (yes, with the old make)

    x -l make -- [-C dir] [-f makefile] [-ns] [VAR=value]... [target]...

    x -l make -- -C myproj            # default goal
    x -l make -- -C myproj -n all     # dry run
    x -l make -- -C myproj CC=clang   # override, locked

It parses and dry-runs x-awk's real Makefile today.  The pure-ish core
is `(mk-run ARGV)`; `(%mk-expand TEXT VARS AUTOS)` is the expansion
engine the suite drives directly.

## Tests

    make test           # the suite, loud on any failure
    make check          # judged against tests/contract/known-failures.txt

## Layout

    lang.xon          what this bundle IS (self-contained: no requires-lang)
    run.x             the entry: seam globals, operands mean "be make"
    mk/prims.x        the platform layer (byte doors, File, Proc)
    mk/expand.x       $(...) expansion: variables, automatics, functions
    mk/parse.x        the line interpreter: conditionals, assignments, rules
    mk/run.x          the DAG walk, mtimes, recipes
    mk/cli.x          options, overrides, mk-main (the exit)
    tests/            markdown specs + the platform's runner, vendored nowhere
