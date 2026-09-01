; # x-make -- a make on x-lang
;
; ## mk/prims.x -- the platform layer
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; Self-contained by design (see lang.xon): the byte doors, File, Proc,
; and the regex engine for glob matching, with the arc's rules applied
; -- raw-allocation for read buffers, no defs at depth in anything hot.

(import x/type/regex)
(import x/sys/file)
(import x/sys/proc)

(provide mk/prims
  char->integer integer->char byte-at byte-len
  string-length substring string-append string-concat string=?
  list->string length reverse append map filter set-first!
  regex-compile regex-match
  file-read-all file-write-all file-exists? file-stat-mtime
  file-list-dir file-unlink
  proc-run proc-capture sys-exit)

(def char->integer (prim-ref (lit char) (lit ->int)))
(def integer->char (prim-ref (lit int) (lit ->char)))
(def byte-at (prim-ref (lit str) (lit byte-ref)))
(def byte-len (prim-ref (lit str) (lit byte-len)))

(def string-length (fn (_ s) (Str8 length s)))
(def substring (fn (_ s a b) (Str8 sub a (- b a) s)))
(def string=? (fn (_ a b) (str=? a b)))

(def %cvt (prim-ref (lit convert) (lit to)))
(def list->string (fn (_ l) (if (null? l) "" (%cvt l %string))))

(def string-append (fn (_ . ss) (string-concat ss)))
(def string-concat
  (fn (self ss)
    (if (null? ss)
      ""
      (if (null? (rest ss)) (first ss) (Str8 append (first ss) (self (rest ss)))))))

(def length (fn (_ l) (List length l)))
(def reverse (fn (_ l) (%mk-rev l ())))
(def %mk-rev
  (fn (self l acc)
    (if (null? l) acc (self (rest l) (pair (first l) acc)))))
(def append (fn (_ a b) (List append a b)))
(def map (fn (_ f l) (List map f l)))
(def filter (fn (_ p l) (List filter p l)))
(def set-first! %set-first!)

(def regex-compile (fn (_ pattern) (Regex compile pattern)))
(def regex-match (fn (_ s rx) (Regex match s rx)))

(def file-read-all (fn (_ path) (File read-all path)))
(def file-write-all (fn (_ path text) (File write-all path text)))
(def file-exists? (fn (_ path) (File exists? path)))
(def file-unlink (fn (_ path) (File unlink path)))
(def file-list-dir (fn (_ path) (File list-dir path)))

; mtime in unix seconds, or nil when the path does not exist
(def file-stat-mtime
  (fn (_ path)
    (if (file-exists? path)
      (let ((d (File stat path)))
        (def go
          (fn (self es)
            (if (null? es) ()
              (if (eq? (first (first es)) (lit mtime))
                (rest (first es))
                (self (rest es))))))
        (go d))
      ())))

(def proc-run (fn (_ argv) (Proc run! argv)))
(def proc-capture (fn (_ argv) (Proc capture argv)))
(def sys-exit (fn (_ n) (Sys exit n)))
