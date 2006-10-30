;;; -*- mode: scheme; coding: utf-8 -*-
;; Extended File System Database
;;
;;  Copyright (c) 2006 Scheme Arts, L.L.C., All rights reserved.
;;  Copyright (c) 2006 Time Intermedia Corporation, All rights reserved.
;;  See COPYING for terms and conditions of using this software
;;
;; $Id: efs.scm,v 1.3 2006/10/30 07:02:41 bizenn Exp $

(define-module kahua.persistence.efs
  (use srfi-1)
  (use srfi-13)
  (use file.util)
  (use gauche.fcntl)
  (use gauche.collection)
  (use gauche.charconv)
  (use gauche.logger)
  (use kahua.persistence)
  (use kahua.util))

(select-module kahua.persistence.efs)

;; Physical Database Structure
;;
;; ${path-to-db}/
;; ${path-to-db}/%%id-counter
;; ${path-to-db}/%%character-encoding
;; ${path-to-db}/%%tmp/
;; ${path-to-db}/${class-name}/
;; ${path-to-db}/${class-name}/%%alive
;; ${path-to-db}/${class-name}/%%key
;; ${path-to-db}/${class-name}/${object-id}
;; ${path-to-db}/${class-name}/%%alive/${object-id} -> ../${object-id}
;; ${path-to-db}/${class-name}/%%key/${keyval}      -> ../${object-id}

;; filesystem-based persistent store (default)

(define-constant *id-counter* "%%id-counter")
(define-constant *character-encoding* "%%character-encoding")
(define-constant *tmpdir* "%%tmp")
(define-constant *alive* "%%alive")
(define-constant *key*   "%%key")
(define-constant *lock-efs* (make <sys-flock> :type F_WRLCK))
(define-constant *unlock-efs* (make <sys-flock> :type F_UNLCK))
(define-constant *file-name-limit* 200)

(define-condition-type <kahua-db-efs-error> <kahua-db-error> kahua-db-efs-error?)
(define (kahua-db-efs-error fmt . args)
  (error <kahua-db-efs-error> :message (apply format fmt args)))

(define mk-dbdir (cut make-directory* <> #o770))

(define-class <kahua-db-efs> (<kahua-db>)
  ((character-encoding :init-value (gauche-character-encoding) :getter character-encoding-of)
   (real-path                 :getter real-path-of)
   (id-counter-path           :getter id-counter-path-of)
   (character-encoding-path   :getter character-encoding-path-of)
   (lock-path                 :getter lock-path-of)
   (tmp-path                  :getter tmp-path-of)
   ))

(define-method initialize ((db <kahua-db-efs>) initargs)
  (define (build-real-path db-path)
    (cond ((#/^efs:/ db-path) => (lambda (m) (rxmatch-after m)))
	  (else db-path)))
  (define (build-lock-path db-path)
    (build-path (sys-dirname db-path) (string-append (sys-basename db-path) ".lock")))
  (define build-id-counter-path         (cut build-path <> *id-counter*))
  (define build-character-encoding-path (cut build-path <> *character-encoding*))
  (define build-tmp-path                (cut build-path <> *tmpdir*))

  (next-method)
  (slot-set! db 'real-path (build-real-path (path-of db)))
  (let1 path (real-path-of db)
    (slot-set! db 'lock-path (build-lock-path path))
    (slot-set! db 'id-counter-path (build-id-counter-path path))
    (slot-set! db 'character-encoding-path (build-character-encoding-path path))
    (slot-set! db 'tmp-path (build-tmp-path path))))

(define (kahua-id-string obj)
  (x->string (kahua-persistent-id obj)))

(define (read-from-file path . opts)
  (let1 reader (get-keyword :reader opts read)
    (apply call-with-input-file path reader opts)))

(define (safe-update-file path tmpbase writer . maybe-encoding)
  (receive (out tmp) (sys-mkstemp tmpbase)
    (guard (e (else
	       (close-output-port out)
	       (sys-unlink tmp)
	       (raise e)))
      (let1 out (or (and-let* ((ce (get-optional maybe-encoding #f)))
		      (wrap-with-output-conversion out ce))
		    out)
	(begin0
	  (writer out)
	  (close-output-port out)
	  (sys-rename tmp path))))))

(define (with-locking-output-file file proc . opts)
  (apply call-with-output-file file
	 (lambda (out)
	   (sys-fcntl out F_SETLKW *lock-efs*)
	   (proc out))
	 ;; Unlock implicitly.
	 opts))

(define-method kahua-db-unique-id ((db <kahua-db-efs>))
  (let1 path  (id-counter-path-of db)
    (with-locking-output-file path
      (lambda (out)
	(let1 next-id (read-from-file path)
	  (safe-update-file path (tmp-path-of db) (pa$ write (+ next-id 1)) #f)
	  next-id))
      :if-exists :append)))

(define-method lock-db ((db <kahua-db-efs>))
  #t)
(define-method unlock-db ((db <kahua-db-efs>))
  #t)

(define-method kahua-db-create ((db <kahua-db-efs>))
  ;; There could be a race condition here, but it would be very
  ;; low prob., so for now it should be OK.
  (let1 tmp (tmp-path-of db)
    (mk-dbdir tmp)
    (with-output-to-file (id-counter-path-of db)
      (cut write 0) :if-exists :error)
    (with-output-to-file (character-encoding-path-of db)
      (cut write (character-encoding-of db)) :if-exists :error))
  db)

;; Check basic directory structure at database open.
(define-method kahua-db-check ((db <kahua-db-efs>))
  (and (file-is-directory? (tmp-path-of db))
       (file-is-regular? (id-counter-path-of db))
       (file-is-regular? (character-encoding-path-of db))))

(define-method kahua-db-open ((db <kahua-db-efs>))
  (define (read-character-encoding db)
    (let ((cefile (character-encoding-path-of db))
	  (ne (gauche-character-encoding)))
      (if (file-is-regular? cefile)
	  (let1 ce (with-input-from-file cefile read)
	    (unless (symbol? ce)
	      (kahua-db-efs-error "kahua-db-open: symbol required by got ~s" ce))
	    (unless (and (symbol? ce) (ces-conversion-supported? ce ne))
	      (kahua-db-efs-error "kahua-db-open: cannot convert from ~s to ~s" ce ne))
	    (unless (ces-upper-compatible? ne ce) ; Warning: because there is a big overhead.
	      (log-format "DB character encoding ~a differ from native ~a" ce ne)
	      (log-format "You should convert it into native encoding ~a" ne))
	    ce)
	  (let1 ce ne
	    (with-output-to-file cefile (cut write ce))
	    ce))))
  (define (check-old-kahua-db-fs db)
    (let1 path (real-path-of db)
      (if (or (file-is-regular? (build-path path "id-counter"))
	      (file-is-directory? (build-path path "tmp")))
	  (kahua-db-efs-error
	   "kahua-db-open: ~s may be old File System Database, so you must convert it into efs" path)
	  (kahua-db-efs-error
	   "kahua-db-open: ~s is broken as efs: please check directory structure." path))))

  (with-locking-output-file (lock-path-of db)
    (lambda _
      (cond ((file-is-directory? (real-path-of db))
	     (if (kahua-db-check db)
		 (slot-set! db 'character-encoding (read-character-encoding db))
		 (check-old-kahua-db-fs db)))
	    (else (kahua-db-create db)))
      (set! (active? db) #t)))
  db)

(define-method kahua-db-close ((db <kahua-db-efs>) commit?)
  (set! (active? db) #f))

(define-method kahua-db-reopen ((db <kahua-db-efs>))
  (set! (active? db) #t)
  db)

(define-method kahua-db-ping ((db <kahua-db-efs>))
  #t)

(define-method start-kahua-db-transaction ((db <kahua-db-efs>))
  (next-method))

(define-method finish-kahua-db-transaction ((db <kahua-db-efs>) commit?)
  (if commit?
      (kahua-db-sync db)
      (kahua-db-rollback db))
  (next-method))

(define-constant *class-name-literal* #[0-9a-zA-Z\-<>])
(define-constant *key-literal* #[0-9a-zA-Z\-<>])

(define (string->path str literal lim encoding)
  (define (proc-byte byte cnt)
    (cond ((>= cnt lim)
	   (write-char #\/) (proc-byte byte 0))
	  ((char-set-contains? literal (integer->char byte))
	   (write-byte byte) (+ cnt 1))
	  (else
	   (format #t "_~2,'0x" byte) (+ cnt 3))))
  (with-string-io (if (ces-equivalent? encoding (gauche-character-encoding))
		      str
		      (ces-convert str (gauche-character-encoding) encoding))
    (lambda ()
      (let1 cnt (port-fold proc-byte 0 read-byte)
      (cond ((= cnt 0) (write-char #\_))
	    ((>= cnt lim) (display "/_")))))))

;; class path(data path):
;;   ${db-path}/${escaped-class-name}

(define (class-name->path-component db cn)
  (string->path (symbol->string cn) *class-name-literal*
		*file-name-limit* (character-encoding-of db)))

(define-method data-path ((db <kahua-db-efs>) (cn <symbol>) . id)
  (apply build-path (real-path-of db)
	 (class-name->path-component db cn) id))

(define-method data-path ((db <kahua-db-efs>) (obj <kahua-persistent-base>))
  (data-path db (class-name (class-of obj)) (kahua-id-string obj)))

(define (create-class-directory* db class)
  (let1 class-path (data-path db (class-name class))
    (unless (file-is-directory? class-path)
      (mk-dbdir class-path)
      (create-alive-directory* db class)
      (create-key-directory* db class))))

;; alive path(hold symlinks to alive(not removed) instances:
;;   ${db-path}/${escaped-class-name}/%%alive/${object-id}

(define-method alive-path ((db <kahua-db-efs>) (cn <symbol>) . id)
  (apply build-path (data-path db cn) *alive* id))

(define-method alive-path ((db <kahua-db-efs>) (obj <kahua-persistent-base>))
  (alive-path db (class-name (class-of obj)) (kahua-id-string obj)))

(define (create-alive-directory* db class)
  (let1 alivedir (alive-path db (class-name class))
    (unless (file-is-directory? alivedir)
      (mk-dbdir alivedir)
      (let1 c (make-kahua-collection db class '(:include-removed-object? #t))
	(for-each (lambda (i)
		    (unless (removed? i)
		      (sys-symlink (build-path ".." (kahua-id-string i))
				   (alive-path db i))))
		  c)))))

(define (maintain-alive-link db obj)
  (define (maintain-simple-symlink db path obj)
    (if (removed? obj)
	(sys-unlink path)
	(unless (file-exists? path)
	  (sys-symlink (build-path ".." (kahua-id-string obj)) path))))
  (maintain-simple-symlink db (alive-path db obj) obj))

;; key path(hold symlinks named as "escaped-key" to alive(not removed) instances:
;;   ${db-path}/${escaped-class-name}/%%key/${escaped-key}

(define (key->path-component key encoding)
  (string->path key *key-literal* *file-name-limit* encoding))

(define (key-symlink-target id-string key-path)
  (let1 rel (regexp-replace-all #/[^\/]+/ key-path "..")
    (build-path rel id-string)))

(define-method key-path ((db <kahua-db-efs>) (cn <symbol>) . maybe-key)
  (or (and-let* ((key (get-optional maybe-key #f)))
	(build-path (data-path db cn) *key* (key->path-component key (character-encoding-of db))))
      (build-path (data-path db cn) *key*)))

(define-method key-path ((db <kahua-db-efs>) (obj <kahua-persistent-base>))
  (key-path db (class-name (class-of obj)) (key-of obj)))

(define (make-key-link target path)
  (mk-dbdir (sys-dirname path))
  (sys-symlink target path))

(define (maintain-key-link db obj)
  (let* ((k (key->path-component (key-of obj) (character-encoding-of db)))
	 (path (build-path (key-path db (class-name (class-of obj)) k)))
	 (target (key-symlink-target (kahua-id-string obj) k)))
    (cond ((file-is-symlink? path)
	   (if (equal? target (sys-readlink path))
	       (when (removed? obj) (sys-unlink path))
	       (kahua-db-efs-error "Error: key ~s conflicts other instance" (key-of obj))))
	  ((removed? obj) (undefined)) ; do nothing
	  (else (make-key-link target path)))))

(define (create-key-directory* db class)
  (let1 keydir (key-path db (class-name class))
    (unless (file-is-directory? keydir)
      (mk-dbdir keydir)
      (for-each (pa$ maintain-key-link db)
		(make-kahua-collection db class '())))))

;;
;; Methods used by kahua.persistence
;;

(define-method read-kahua-instance ((db <kahua-db-efs>) (class <kahua-persistent-meta>)
				    (id <integer>))
  (let1 path (data-path db (class-name class) (x->string id))
    (and (file-is-regular? path)
	 (read-from-file path :encoding (character-encoding-of db)))))

(define-method read-kahua-instance ((db <kahua-db-efs>)
                                    (class <kahua-persistent-meta>)
                                    (key <string>) . maybe-include-removed-object?)
  (if (get-optional maybe-include-removed-object? #f)
      (call/cc (lambda (ret)
		 (for-each (lambda (id)
			     (and-let* ((obj (kahua-instance class (x->integer id) #t)))
			       (and (equal? key (key-of obj)) (ret obj))))
			   (directory-list (data-path db (class-name class)) :children #t
					   :filter file-is-regular? :filter-add-path? #t))
		 #f))
      (let1 path (key-path db (class-name class) key)
	(and (file-exists? path)
	     (read-from-file path :encoding (character-encoding-of db))))))

(define-method write-kahua-instance ((db <kahua-db-efs>)
                                     (obj <kahua-persistent-base>))
  (create-class-directory* db (class-of obj))
  (let* ((file-path (data-path db obj))
	 (writer (lambda (out)
		   (with-port-locking out (cut kahua-write obj out)))))
    (if (ref obj '%floating-instance)
	(guard (e (else (kahua-db-efs-error "duplicate key: ~s" (key-of obj))))
	  (call-with-output-file file-path
	    writer
	    :if-exists :error
	    :encoding (character-encoding-of db)))
	(with-locking-output-file file-path
	  (lambda _
	    (safe-update-file file-path (tmp-path-of db) writer (character-encoding-of db)))
	  :if-exists :append))
    (maintain-alive-link db obj)
    (maintain-key-link db obj)
    (set! (ref obj '%floating-instance) #f)))

;; deprecated
(define-method kahua-db-write-id-counter ((db <kahua-db-efs>))
  #f)

(define (directory-list* path . opts)
  (if (file-is-directory? path)
      (apply directory-list path opts)
      '()))

(define-method kahua-persistent-instances ((db <kahua-db-efs>) class keys filter-proc include-removed-object?)
  (let* ((cn (class-name class))
	 (filter (cond (include-removed-object?
			(lambda (obj)
			  (and obj (or (not keys) (member (key-of obj) keys)) (filter-proc obj))))
		       (else filter-proc))))
    (cond (include-removed-object?
	   (filter-map (lambda (id)
			 (and-let* ((obj (kahua-instance class (x->integer id) include-removed-object?)))
			   (filter obj)))
		       (directory-list* (data-path db cn) :children? #t
					:filter file-is-regular? :filter-add-path? #t)))
	  (keys
	   (filter-map (lambda (k)
			 (and-let* ((obj (find-kahua-instance class k include-removed-object?)))
			   (filter obj)))
		       keys))
	  (else
	   (filter-map (lambda (id)
			 (and-let* ((obj (kahua-instance class (x->integer id) include-removed-object?)))
			   (filter obj)))
		       (directory-list* (alive-path db cn) :children #t
					:filter file-is-symlink? :filter-add-path? #t))))))

;;=================================================================
;; Database Consistency Check and Fix
;;

(define-method dbutil:instance-files-fold ((db <kahua-db-efs>) class-name proc knil)
  (fold proc knil
	(directory-list (data-path db class-name) :add-path? #t :children? #t
			:filter file-is-regular? :filter-add-path? #t)))

;; Sweep all instances' object id and compare max of them with id-counter
;;
(define-method dbutil:check-id-counter ((db <kahua-db-efs>) do-fix?)
  (let* ((ce (character-encoding-of db))
	 (max-id (dbutil:persistent-classes-fold
		  db (lambda (cn r)
		       (dbutil:instance-files-fold
			db cn (lambda (p r)
				(max r (ref (with-input-from-file p read :encoding ce) 'id)))
			r))
		  0)))
    (cond ((> (or (with-input-from-file (id-counter-path-of db)
		    read :if-does-not-exist #f) 0)
	      max-id)                                     'OK)
	  (do-fix? (safe-update-file (id-counter-path-of db) (tmp-path-of db)
				(pa$ write (+ max-id 1))) 'FIXED)
	  (else                                           'NG))))

;; Sweep all instances data as raw string, and check each data character
;; encoding is match with (character-encoding-of db).
;;
(define-method dbutil:check-character-encoding ((db <kahua-db-efs>) do-fix?)
  (define (string-compatible? bs ces1 ces2)
    (guard (e (else #f))
      (let ((s1 (ces-convert bs ces1))
	    (s2 (ces-convert bs ces2)))
	(string=? s1 s2))))
  (define (convert p bs from to)
    (cond (do-fix?
	   (safe-update-file p (tmp-path-of db)
			(pa$ display (ces-convert bs from))
			to)
	   'FIXED)
	  (else 'NG)))
  (let1 ce (character-encoding-of db)
    (dbutil:persistent-classes-fold
     db (lambda (cn r)
	  (dbutil:instance-files-fold
	   db cn (lambda (p r)
		   (let* ((s (sys-stat p))
			  (size (ref s 'size))
			  (data (with-input-from-file p (cut read-block size)))
			  (gce (ces-guess-from-string data "*JP")))
		     (if (or (ces-equivalent? ce gce)
			     (string-compatible? data ce gce))
			 r
			 (convert p data gce ce))))
	   r))
     'OK)))

;; Check alive directory (%%alive under each class directory) and removed flag of
;; all instances.
;;
(define-method dbutil:check-removed-flag-facility ((db <kahua-db-efs>) do-fix?)
  (define (%fix-alive-path apath removed? r)
    (cond (removed?
	   (if (file-exists? apath)
	       (cond (do-fix? (sys-remove apath) 'FIXED)
		     (else                       'NG))
	       r))
	  ((file-is-symlink? apath) r)
	  (do-fix? (sys-symlink (build-path ".." (sys-basename apath)) apath) 'FIXED)
	  (else                                                               'NG)))
  (define (%fix-alive-directory adir)
    (and do-fix? (mk-dbdir adir) 'FIXED))
  (let1 ce (character-encoding-of db)
    (dbutil:persistent-classes-fold
     db (lambda (cn r)
	  (let1 adir (alive-path db cn)
	    (if (or (file-is-directory? adir)
		    (%fix-alive-directory adir))
		(dbutil:instance-files-fold
		 db cn (lambda (p r)
			 (let* ((i (with-input-from-file p read :encoding ce))
				(removed? (ref i 'removed?))
				(apath (alive-path db cn (sys-basename p))))
			   (%fix-alive-path apath removed? r)))
		 r)
		'NG)))
     'OK)))

(define-constant *proc-table*
  `((,dbutil:check-character-encoding . "Database character encoding... ")
    (,dbutil:check-id-counter         . "Database ID counter... ")
    (,dbutil:check-removed-flag-facility . "Database removed flags... ")))

(define-method dbutil:check&fix-database ((db <kahua-db-efs>) writer do-fix?)
  (for-each (lambda (e)
	      (let ((do-check (car e))
		    (msg-prefix (cdr e)))
		(writer msg-prefix)
		(writer (do-check db do-fix?))
		(writer "\n")))
	    *proc-table*))

;; This is very transitional code.
;; FIXME!!
(define-method dbutil:kahua-db-fs->efs ((path <string>))
  (define (fix-id-counter)
    (let ((old-id-counter (build-path path "id-counter"))
	  (new-id-counter (build-path path *id-counter*)))
      (when (and (file-is-regular? old-id-counter)
		 (integer? (read-from-file old-id-counter)))
	(sys-rename old-id-counter new-id-counter))))
  (define (fix-tmp-directory)
    (let ((old-tmp-dir (build-path path "tmp"))
	  (new-tmp-dir (build-path path *tmpdir*)))
      (when (file-is-directory? old-tmp-dir)
	(sys-rename old-tmp-dir new-tmp-dir))))
  (define (get-character-encoding)
    (let1 ce-path (build-path path *character-encoding*)
      (if (file-is-regular? ce-path)
	  (read-from-file ce-path)
	  (gauche-character-encoding))))
  (define (class-directory-list)
    (remove (lambda (d)
	      (member (sys-basename d) `("tmp" ,*tmpdir*)))
	    (directory-list path :add-path? #t :children? #t
			    :filter file-is-directory? :filter-add-path? #t)))
  (define (instance-file-list dir)
    (directory-list dir :add-path? #t :children? #t
		    :filter file-is-regular? :filter-add-path? #t))
  (define (fix-key-link keydir f id-string encoding)
    (let* ((old-key (sys-basename f))
	   (new-key (key->path-component old-key encoding))
	   (key-path (build-path keydir new-key)))
      (mk-dbdir (sys-dirname key-path))
      (sys-symlink (key-symlink-target id-string new-key) key-path)))
  (define (fix-alive-link alivedir f id-string)
    (let* ((old-link (build-path alivedir (sys-basename f)))
	   (new-link (build-path alivedir id-string)))
      (sys-unlink old-link)
      (sys-symlink (build-path ".." id-string) new-link)))
  (define (fix-instance-path f id-string)
    (sys-rename f (build-path (sys-dirname f) id-string)))
  (define (fix-class-directory dir)
    (let* ((alivedir (build-path dir *alive*))
	   (keydir (build-path dir *key*))
	   (tmpdir (build-path dir "%%transitional"))
	   (encoding (get-character-encoding))
	   (reader (cut read-from-file <> :encoding encoding)))
      (mk-dbdir alivedir)
      (mk-dbdir keydir)
      (mk-dbdir tmpdir)
      (let1 new-cn (fold (lambda (f cn)
			   (let* ((obj (reader f))
				  (id  (x->string (ref obj 'id)))
				  (cn (ref obj 'class-name))
				  (key (sys-basename f)))
			     (fix-key-link keydir f id encoding)
			     (fix-alive-link alivedir f id)
			     (fix-instance-path f id)
			     cn))
			 (string->symbol (sys-basename dir))
			 (instance-file-list dir))
	(sys-rename dir (build-path (sys-dirname dir) (symbol->string new-cn))))
	))

  (fix-id-counter)
  (fix-tmp-directory)
  (dbutil:with-dummy-reader-ctor
   (cut map fix-class-directory (class-directory-list))))

(provide "kahua/persistence/efs")
