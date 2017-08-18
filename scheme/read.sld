;;;; Cyclone Scheme
;;;; https://github.com/justinethier/cyclone
;;;;
;;;; Copyright (c) 2014-2016, Justin Ethier
;;;; All rights reserved.
;;;;
;;;; This module contains the s-expression parser and supporting functions.
;;;;
(define-library (scheme read)
  (import (scheme base)
          ;(scheme write)
          (scheme char))
  (export
    read
    read-all
    include
    include-ci)
  (begin

(define-syntax include
  (er-macro-transformer
   (lambda (expr rename compare)
     (apply
      append
      (cons
        '(begin)
         (map
          (lambda (filename)
            (call-with-port
              (open-input-file filename)
              (lambda (port)
                (read-all port))))
          (cdr expr)))))))

(define-syntax include-ci
  (er-macro-transformer
   (lambda (expr rename compare)
    `(include ,@(cdr expr)))))

;; Convert a list read by the reader into an improper list
(define (->dotted-list lst)
  (cond
    ((null? lst) '())
    ((equal? (car lst) (string->symbol "."))
     (cadr lst))
    (else
      (cons (car lst) (->dotted-list (cdr lst))))))
  
;; Main lexer/parser
(define read
  (lambda args
    (let ((fp (if (null? args)
                  (current-input-port)
                    (car args))))
      (let ((result (parse fp)))
        (if (Cyc-opaque? result)
          (read-error fp "unexpected closing parenthesis")
          result)))))

;; read-all -> port -> [objects]
(define (read-all . args)
  (let ((fp (if (null? args)
                (current-input-port)
                (car args))))
    (define (loop fp result)
      (let ((obj (read fp)))
        (if (eof-object? obj)
          (reverse result)
          (loop fp (cons obj result)))))
    (loop fp '())))

;;(define-c reading-from-file?
;;  "(void *data, int argc, closure _, object k, object port)"
;;  " object result = boolean_f;
;;    Cyc_check_port(data, port);
;;    if (((port_type *)port)->flags == 1) {
;;      result = boolean_t;
;;    }
;;    return_closcall1(data, k, result);")

(define-c read-token
  "(void *data, int argc, closure _, object k, object port)"
  " Cyc_io_read_token(data, k, port);")

(define-c read-error
  "(void *data, int argc, closure _, object k, object port, object msg)"
  " char buf[1024];
    port_type *p;
    Cyc_check_port(data, port);
    Cyc_check_str(data, msg);
    p = ((port_type *)port);
    snprintf(buf, 1023, \"(line %d, column %d): %s\", 
           p->line_num, p->col_num, string_str(msg));
    Cyc_rt_raise_msg(data, buf);")

(define-c Cyc-opaque-eq?
  "(void *data, int argc, closure _, object k, object opq, object obj)"
  " if (Cyc_is_opaque(opq) == boolean_f) 
      return_closcall1(data, k, boolean_f);
    return_closcall1(data, k, equalp( opaque_ptr(opq), obj ));")

(define-c Cyc-opaque-unsafe-eq?
  "(void *data, int argc, closure _, object k, object opq, object obj)"
  " return_closcall1(data, k, equalp( opaque_ptr(opq), obj ));")

(define (parse fp)
  (let ((token (read-token fp)))
    ;(write `(token ,token))
    (cond
      ((Cyc-opaque? token)
       (cond
         ;; Open paren, start read loop
         ((Cyc-opaque-unsafe-eq? token #\()
          (let loop ((lis '())
                     (t (parse fp)))
            (cond
              ((eof-object? t)
               (read-error fp "missing closing parenthesis"))
              ((Cyc-opaque-eq? t #\))
               (if (and (> (length lis) 2)
                        (equal? (cadr lis) (string->symbol ".")))
                   (->dotted-list (reverse lis))
                   (reverse lis)))
              (else
               (loop (cons t lis) (parse fp))))))
         ((Cyc-opaque-unsafe-eq? token #\')
          (list 'quote (parse fp)))
         ((Cyc-opaque-unsafe-eq? token #\`)
          (list 'quasiquote (parse fp)))
         ((Cyc-opaque-unsafe-eq? token #\,)
          (list 'unquote (parse fp)))
         (else
          token))) ;; error if this is returned to original caller of parse
      ((vector? token)
       (cond
        ((= (vector-length token) 2) ;; Special case: number
         (string->number (vector-ref token 0) (vector-ref token 1)))
        ((= (vector-length token) 3) ;; Special case: exact/inexact number
         (if (vector-ref token 2)
             (exact (string->number (vector-ref token 0) (vector-ref token 1)))
             (inexact (string->number (vector-ref token 0) (vector-ref token 1)))))
        ((= (vector-length token) 1) ;; Special case: error
         (error (vector-ref token 0)))
        (else
         (let loop ((lis '())
                    (t (parse fp)))
           (cond
             ((eof-object? t)
              (read-error fp "missing closing parenthesis"))
             ((Cyc-opaque-eq? t #\))
              (list->vector (reverse lis)))
             (else
              (loop (cons t lis) (parse fp))))))))
      ((bytevector? token)
       (let loop ((lis '())
                  (t (parse fp)))
         (cond
           ((eof-object? t)
            (read-error fp "missing closing parenthesis"))
           ((Cyc-opaque-eq? t #\))
            (apply bytevector (reverse lis)))
           (else
            (loop (cons t lis) (parse fp))))))
      ((eq? token (string->symbol ",@"))
       (list 'unquote-splicing (parse fp)))
      ((eq? token (string->symbol "#;"))
       (parse fp) ;; Ignore next datum
       (parse fp))
      ;; Other special cases?
      (else
        token))))
  ))
