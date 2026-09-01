# @weight 1

The expansion engine, pure: a vars box, text in, text out.

## variables

### recursive and simple, long and short spellings

```make
(do (def v (list ())) (%mk-var-set! v "X" (lit rec) "wor$(Y)") (%mk-var-set! v "Y" (lit rec) "ld") (display (%mk-expand "hello $(X)!" v ())))
```
---
    hello world!

### an undefined variable is empty

```make
(do (def v (list ())) (display (%mk-expand "a$(NOPE)b" v ())))
```
---
    ab

### dollar-dollar is a dollar

```make
(do (def v (list ())) (display (%mk-expand "cost $$5" v ())))
```
---
    cost $5

### the automatics overlay wins

```make
(do (def v (list ())) (%mk-var-set! v "@" (lit rec) "table") (display (%mk-expand "$@ and $(@)" v (list (pair "@" "auto")))))
```
---
    auto and auto

## functions

### subst

```make
(do (def v (list ())) (display (%mk-expand "$(subst ee,EE,feet on street)" v ())))
```
---
    fEEt on strEEt

### patsubst

```make
(do (def v (list ())) (display (%mk-expand "$(patsubst %.c,%.o,a.c b.c c.h)" v ())))
```
---
    a.o b.o c.h

### findstring

```make
(do (def v (list ())) (display (%mk-expand "[$(findstring a,abc)][$(findstring z,abc)]" v ())))
```
---
    [a][]

### if

```make
(do (def v (list ())) (%mk-var-set! v "Y" (lit rec) "1") (display (%mk-expand "$(if $(Y),yes,no)/$(if $(N),yes,no)" v ())))
```
---
    yes/no

### basename dir notdir

```make
(do (def v (list ())) (display (%mk-expand "$(basename src/a.c)|$(dir src/a.c)|$(notdir src/a.c)" v ())))
```
---
    src/a|src/|a.c

### strip

```make
(do (def v (list ())) (display (%mk-expand "[$(strip   a   b  )]" v ())))
```
---
    [a b]

### shell

```make
(do (def v (list ())) (display (%mk-expand "$(shell printf 'one two')" v ())))
```
---
    one two
