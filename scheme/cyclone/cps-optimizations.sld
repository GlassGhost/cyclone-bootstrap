;;;; Cyclone Scheme
;;;; https://github.com/justinethier/cyclone
;;;;
;;;; Copyright (c) 2014-2016, Justin Ethier
;;;; All rights reserved.
;;;;
;;;; This module performs CPS analysis and optimizations.
;;;;

;(define-library (cps-optimizations) ;; For debugging via local unit tests
(define-library (scheme cyclone cps-optimizations)
  (import (scheme base)
          (scheme cyclone util)
          (scheme cyclone ast)
          (scheme cyclone primitives)
          (scheme cyclone transforms)
          (srfi 69))
  (export
      optimize-cps 
      analyze-cps
      opt:contract
      opt:inline-prims
      adb:clear!
      adb:get
      adb:get/default
      adb:set!
      adb:get-db
      simple-lambda?
      one-instance-of-new-mutable-obj?
      ;; Analyze variables
      adb:make-var
      %adb:make-var
      adb:variable?
      adbv:global?  
      adbv:set-global!
      adbv:defined-by 
      adbv:set-defined-by!
      adbv:reassigned? 
      adbv:set-reassigned!
      adbv:assigned-value
      adbv:set-assigned-value!
      adbv:const? 
      adbv:set-const!
      adbv:const-value
      adbv:set-const-value!
      adbv:ref-by
      adbv:set-ref-by!
      ;; Analyze functions
      adb:make-fnc
      %adb:make-fnc
      adb:function?
      adbf:simple adbf:set-simple!
      adbf:unused-params adbf:set-unused-params!
      ;; Analyze user defined functions
      udf:inline
  )
  (begin
    (define *adb* (make-hash-table))
    (define (adb:get-db) *adb*)
    (define (adb:clear!)
      (set! *adb* (make-hash-table)))
    (define (adb:get key) (hash-table-ref *adb* key))
    (define (adb:get/default key default) (hash-table-ref/default *adb* key default))
    (define (adb:set! key val) (hash-table-set! *adb* key val))
    (define-record-type <analysis-db-variable>
      (%adb:make-var global defined-by const const-value  ref-by
                     reassigned assigned-value app-fnc-count app-arg-count)
      adb:variable?
      (global adbv:global? adbv:set-global!)
      (defined-by adbv:defined-by adbv:set-defined-by!)
      (const adbv:const? adbv:set-const!)
      (const-value adbv:const-value adbv:set-const-value!)
      (ref-by adbv:ref-by adbv:set-ref-by!)
      ;; TODO: need to set reassigned flag if variable is SET, however there is at least
      ;; one exception for local define's, which are initialized to #f and then assigned
      ;; a single time via set
      (reassigned adbv:reassigned? adbv:set-reassigned!)
      (assigned-value adbv:assigned-value adbv:set-assigned-value!)
      ;; Number of times variable appears as an app-function
      (app-fnc-count adbv:app-fnc-count adbv:set-app-fnc-count!)
      ;; Number of times variable is passed as an app-argument
      (app-arg-count adbv:app-arg-count adbv:set-app-arg-count!)
    )

    (define (adbv-set-assigned-value-helper! sym var value)
      (define (update-lambda-atv! syms value)
;(trace:error `(update-lambda-atv! ,syms ,value))
        (cond
          ((ast:lambda? value)
           (let ((id (ast:lambda-id value)))
             (with-fnc! id (lambda (fnc)
               (adbf:set-assigned-to-var! 
                 fnc 
                 (append syms (adbf:assigned-to-var fnc)))))))
          ;; Follow references
          ((ref? value)
           (with-var! value (lambda (var)
             (update-lambda-atv! (cons value syms) (adbv:assigned-value var)))))
          (else
            #f))
      )
      (adbv:set-assigned-value! var value)
      ;; TODO: if value is a lambda, update the lambda's var ref's
      ;; BUT, what if other vars point to var? do we need to add
      ;; them to the lambda's list as well?
      (update-lambda-atv! (list sym) value)
    )

    (define (adb:make-var)
      (%adb:make-var '? '? #f #f '() #f #f 0 0))

    (define-record-type <analysis-db-function>
      (%adb:make-fnc simple unused-params assigned-to-var)
      adb:function?
      (simple adbf:simple adbf:set-simple!)
      (unused-params adbf:unused-params adbf:set-unused-params!)
      (assigned-to-var adbf:assigned-to-var adbf:set-assigned-to-var!)
      ;; TODO: top-level-define ?
    )
    (define (adb:make-fnc)
      (%adb:make-fnc '? '? '()))

    ;; A constant value that cannot be mutated
    ;; A variable only ever assigned to one of these could have all
    ;; instances of itself replaced with the value.
    (define (const-atomic? exp)
      (or (integer? exp)
          (real? exp)
          ;(string? exp)
          ;(vector? exp)
          ;(bytevector? exp)
          (char? exp)
          (boolean? exp)))

    ;; Helper to retrieve the Analysis DB Variable referenced
    ;; by sym (or use a default if none is found), and call
    ;; fnc with that ADBV.
    ;;
    ;; The analysis DB is updated with the variable, in case
    ;; it was not found.
    (define (with-var! sym fnc)
      (let ((var (adb:get/default sym (adb:make-var))))
        (fnc var)
        (adb:set! sym var)))

    ;; Non-mutating version, returns results of fnc
    (define (with-var sym fnc)
      (let ((var (adb:get/default sym (adb:make-var))))
        (fnc var)))

    (define (with-fnc! id callback)
      (let ((fnc (adb:get/default id (adb:make-fnc))))
        (callback fnc)
        (adb:set! id fnc)))

;; TODO: check app for const/const-value, also (for now) reset them
;; if the variable is modified via set/define
    (define (analyze exp lid)
;(trace:error `(analyze ,lid ,exp ,(app? exp)))
      (cond
        ; Core forms:
        ((ast:lambda? exp)
         (let* ((id (ast:lambda-id exp))
                (fnc (adb:get/default id (adb:make-fnc))))
           ;; save lambda to adb
           (adb:set! id fnc)
           ;; Analyze the lambda
;(trace:error `(DEBUG-exp ,exp))
;(trace:error `(DEUBG-ast ,(ast:lambda-formals->list exp)))
           (for-each
            (lambda (arg)
              ;(let ((var (adb:get/default arg (adb:make-var))))
              (with-var! arg (lambda (var)
                (adbv:set-global! var #f)
                (adbv:set-defined-by! var id))))
            (ast:lambda-formals->list exp))
           (for-each
             (lambda (expr)
               (analyze expr id))
             (ast:lambda-body exp))))
        ((const? exp) #f)
        ((quote? exp) #f)
        ((ref? exp)
         (let ((var (adb:get/default exp (adb:make-var))))
          (adbv:set-ref-by! var (cons lid (adbv:ref-by var)))
         ))
        ((define? exp)
         ;(let ((var (adb:get/default (define->var exp) (adb:make-var))))
         (with-var! (define->var exp) (lambda (var)
           (adbv:set-defined-by! var lid)
           (adbv:set-ref-by! var (cons lid (adbv:ref-by var)))
           (adbv-set-assigned-value-helper! (define->var exp) var (define->exp exp))
           (adbv:set-const! var #f)
           (adbv:set-const-value! var #f)))
         (analyze (define->exp exp) lid))
        ((set!? exp)
         ;(let ((var (adb:get/default (set!->var exp) (adb:make-var))))
         (with-var! (set!->var exp) (lambda (var)
           (if (adbv:assigned-value var)
               (adbv:set-reassigned! var #t))
           (adbv-set-assigned-value-helper! (set!->var exp) var (set!->exp exp))
           (adbv:set-ref-by! var (cons lid (adbv:ref-by var)))
           (adbv:set-const! var #f)
           (adbv:set-const-value! var #f)))
         (analyze (set!->exp exp) lid))
        ((if? exp)       `(if ,(analyze (if->condition exp) lid)
                              ,(analyze (if->then exp) lid)
                              ,(analyze (if->else exp) lid)))
        
        ; Application:
        ((app? exp)
         (if (ref? (car exp))
             (with-var! (car exp) (lambda (var)
               (adbv:set-app-fnc-count! var (+ 1 (adbv:app-fnc-count var))))))
         (for-each
          (lambda (arg)
             (if (ref? arg)
                 (with-var! arg (lambda (var)
                   (adbv:set-app-arg-count! var (+ 1 (adbv:app-arg-count var)))))))
          (app->args exp))

         ;; TODO: if ast-lambda (car),
         ;; for each arg
         ;;  if arg is const-atomic
         ;;     mark the parameter (variable) as const and give it const-val
         ;;
         ;; obviously need to add code later on to reset const if mutated
         (cond
          ((and (ast:lambda? (car exp))
                (list? (ast:lambda-args (car exp)))) ;; For now, avoid complications with optional/extra args
           (let ((params (ast:lambda-args (car exp))))
             (for-each
              (lambda (arg)
;(trace:error `(app check arg ,arg ,(car params) ,(const-atomic? arg)))
                (with-var! (car params) (lambda (var)
                  (adbv-set-assigned-value-helper! (car params) var arg)
                  (cond
                   ((const-atomic? arg)
                    (adbv:set-const! var #t)
                    (adbv:set-const-value! var arg)))))
                ;; Walk this list, too
                (set! params (cdr params)))
              (app->args exp)))))
         (for-each
           (lambda (e)
             (analyze e lid))
           exp))
;TODO         ((app? exp)      (map (lambda (e) (wrap-mutables e globals)) exp))

        ; Nothing to analyze for these?
        ;((prim? exp)     exp)
        ;((quote? exp)    exp)
        ; Should never see vanilla lambda's in this function, only AST's
        ;((lambda? exp)
        ;; Nothing to analyze for expressions that fall into this branch
        (else
          #f)))

    (define (analyze2 exp)
      (cond
        ; Core forms:
        ((ast:lambda? exp)
         (let* ((id (ast:lambda-id exp))
                (fnc (adb:get id)))
;(trace:error `(adb:get ,id ,fnc))
           (adbf:set-simple! fnc (simple-lambda? exp))
           (for-each
             (lambda (expr)
               (analyze2 expr))
             (ast:lambda-body exp))))
        ((const? exp) #f)
        ((quote? exp) #f)
;; TODO:
;        ((ref? exp)
;         (let ((var (adb:get/default exp (adb:make-var))))
;          (adbv:set-ref-by! var (cons lid (adbv:ref-by var)))
;         ))
        ((define? exp)
         ;(let ((var (adb:get/default (define->var exp) (adb:make-var))))
           (analyze2 (define->exp exp)))
        ((set!? exp)
         ;(let ((var (adb:get/default (set!->var exp) (adb:make-var))))
           (analyze2 (set!->exp exp)))
        ((if? exp)       `(if ,(analyze2 (if->condition exp))
                              ,(analyze2 (if->then exp))
                              ,(analyze2 (if->else exp))))
        ; Application:
        ((app? exp)
         (for-each (lambda (e) (analyze2 e)) exp))
        (else #f)))

    ;; TODO: make another pass for simple lambda's
    ;can use similar logic to cps-optimize-01:
    ;- body is a lambda app
    ;- no lambda args are referenced in the body of that lambda app
    ;  (ref-by is empty or the defining lid)
    ;
    ; Need to check analysis DB against CPS generated and make sure
    ; things like ref-by make sense (ref by seems like its only -1 right now??)
    ;; Does ref-by list contains references to lambdas other than owner?
    ;; int -> ast-variable -> boolean
    (define (nonlocal-ref? owner-id adb-var)
      (define (loop ref-by-ids)
        (cond
          ((null? ref-by-ids) #f)
          ((not (pair? ref-by-ids)) #f)
          (else
            (let ((ref (car ref-by-ids)))
              (if (and (number? ref) (not (= owner-id ref)))
                  #t ;; Another lambda uses this variable
                  (loop (cdr ref-by-ids)))))))
      (loop (adbv:ref-by adb-var)))
      
    ;; int -> [symbol] -> boolean
    (define (any-nonlocal-refs? owner-id vars)
      (call/cc 
        (lambda (return)
          (for-each
            (lambda (var)
              (if (nonlocal-ref? owner-id (adb:get var))
                  (return #t)))
            vars)
          (return #f))))

    ;; ast-function -> boolean
    (define (simple-lambda? ast)
      (let ((body (ast:lambda-body ast))
            (formals (ast:lambda-formals->list ast))
            (id (ast:lambda-id ast)))
        (if (pair? body)
            (set! body (car body)))
;(trace:error `(simple-lambda? ,id ,formals 
;,(and (pair? body)
;     (app? body)
;     (ast:lambda? (car body)))
;,(length formals)
;;,body
;))
        (and (pair? body)
             (app? body)
             (ast:lambda? (car body))
             (> (length formals) 0)
             (equal? (app->args body)
                     formals)
             (not (any-nonlocal-refs? id formals))
    )))

    ;; Perform contraction phase of CPS optimizations
    (define (opt:contract exp)
      (cond
        ; Core forms:
        ((ast:lambda? exp)
         (let* ((id (ast:lambda-id exp))
                (fnc (adb:get id)))
           (if (adbf:simple fnc)
               (opt:contract (caar (ast:lambda-body exp))) ;; Optimize-out the lambda
               (ast:%make-lambda
                 (ast:lambda-id exp)
                 (ast:lambda-args exp)
                 (opt:contract (ast:lambda-body exp))))))
        ((const? exp) exp)
        ((ref? exp) 
         (let ((var (adb:get/default exp #f)))
           (if (and var (adbv:const? var))
               (adbv:const-value var)
               exp)))
        ((prim? exp) exp)
        ((quote? exp) exp)
        ((define? exp)
         `(define ,(opt:contract (define->var exp))
                  ,@(opt:contract (define->exp exp))))
        ((set!? exp)
         `(set! ,(opt:contract (set!->var exp))
                ,(opt:contract (set!->exp exp))))
        ((if? exp)
         (cond
          ((not (if->condition exp))
           (opt:contract (if->else exp)))
          (else 
            `(if ,(opt:contract (if->condition exp))
                 ,(opt:contract (if->then exp))
                 ,(opt:contract (if->else exp))))))
        ; Application:
        ((app? exp)
         (let* ((fnc (opt:contract (car exp))))
           (cond
            ((and (ast:lambda? fnc)
                  (list? (ast:lambda-args fnc)) ;; Avoid optional/extra args
                  (= (length (ast:lambda-args fnc))
                     (length (app->args exp))))
             (let ((new-params '())
                   (new-args '())
                   (args (cdr exp)))
               (for-each
                 (lambda (param)
                   (let ((var (adb:get/default param #f)))
                     (cond
                      ((and var (adbv:const? var))
                       #f)
                      (else
                       ;; Collect the params/args not optimized-out
                       (set! new-args (cons (car args) new-args))
                       (set! new-params (cons param new-params))))
                     (set! args (cdr args))))
                 (ast:lambda-args fnc))
;(trace:e  rror `(DEBUG contract args ,(app->args exp) 
;                                new-args ,new-args
;                                params ,(ast:lambda-args fnc) 
;                                new-params ,new-params))
               (cons
                 (ast:%make-lambda
                   (ast:lambda-id fnc)
                   (reverse new-params)
                   (ast:lambda-body fnc))
                 (map 
                   opt:contract
                     (reverse new-args)))))
            (else
             (cons 
               fnc
               (map (lambda (e) (opt:contract e)) (cdr exp)))))))
        (else 
          (error "CPS optimize [1] - Unknown expression" exp))))

    ;; Inline primtives
    ;; Uses analysis DB, so must be executed after analysis phase
    ;;
    ;; TBD: better to enhance CPS conversion to do this??
    (define (opt:inline-prims exp . refs*)
      (let ((refs (if (null? refs*)
                      (make-hash-table)
                      (car refs*))))
;(trace:error `(opt:inline-prims ,exp))
        (cond
          ((ref? exp) 
           ;; Replace lambda variables, if necessary
           (let ((key (hash-table-ref/default refs exp #f)))
             (if key
                 (opt:inline-prims key refs)
                 exp)))
          ((ast:lambda? exp)
           (ast:%make-lambda
            (ast:lambda-id exp)
            (ast:lambda-args exp)
            (map (lambda (b) (opt:inline-prims b refs)) (ast:lambda-body exp))))
          ((const? exp) exp)
          ((quote? exp) exp)
          ((define? exp)
           `(define ,(define->var exp)
                    ,@(opt:inline-prims (define->exp exp) refs))) ;; TODO: map????
          ((set!? exp)
           `(set! ,(set!->var exp)
                  ,(opt:inline-prims (set!->exp exp) refs)))
          ((if? exp)       
           (cond
            ((not (if->condition exp))
             (opt:inline-prims (if->else exp) refs)) ;; Always false, so replace with else
            ((const? (if->condition exp))
             (opt:inline-prims (if->then exp) refs)) ;; Always true, replace with then
            (else
              `(if ,(opt:inline-prims (if->condition exp) refs)
                   ,(opt:inline-prims (if->then exp) refs)
                   ,(opt:inline-prims (if->else exp) refs)))))
          ; Application:
          ((app? exp)
;(trace:error `(app? ,exp ,(ast:lambda? (car exp))
;              ,(length (cdr exp))
;              ,(length (ast:lambda-formals->list (car exp)))
;              ,(all-prim-calls? (cdr exp))))
           (cond
            ((and (ast:lambda? (car exp))
                  ;; TODO: check for more than one arg??
                  (equal? (length (cdr exp))
                          (length (ast:lambda-formals->list (car exp))))
                  ;; Double-check parameter can be optimized-out
                  (every
                    (lambda (param)
                      (with-var param (lambda (var)
;(trace:error `(DEBUG ,param ,(adbv:ref-by var)))
                        (and 
                          ;; If param is never referenced, then prim is being
                          ;; called for side effects, possibly on a global
                          (not (null? (adbv:ref-by var)))
                          ;; Need to keep variable because it is mutated
                          (not (adbv:reassigned? var))
                    ))))
                    (ast:lambda-formals->list (car exp)))
                  ;; Check all args are valid primitives that can be inlined
                  (every
                    (lambda (arg)
                      (and (prim-call? arg)
                           (not (prim:cont? (car arg)))))
                    (cdr exp))
                  ;; Disallow primitives that allocate a new obj,
                  ;; because if the object is mutated all copies
                  ;; must be modified. 
                  (one-instance-of-new-mutable-obj?
                    (cdr exp)
                    (ast:lambda-formals->list (car exp)))
                  (inline-prim-call? 
                    (ast:lambda-body (car exp))
                    (prim-calls->arg-variables (cdr exp))
                    (ast:lambda-formals->list (car exp)))
             )
             (let ((args (cdr exp)))
               (for-each
                (lambda (param)
                  (hash-table-set! refs param (car args))
                  (set! args (cdr args)))
                (ast:lambda-formals->list (car exp))))
             (opt:inline-prims (car (ast:lambda-body (car exp))) refs))
            (else
              (map (lambda (e) (opt:inline-prims e refs)) exp))))
          (else 
            (error `(Unexpected expression passed to opt:inline-prims ,exp))))))

    ;; Do all the expressions contain prim calls?
    (define (all-prim-calls? exps)
      (cond
        ((null? exps) #t)
        ((prim-call? (car exps))
         (all-prim-calls? (cdr exps)))
        (else #f)))

    ;; Find all variables passed to all prim calls
    (define (prim-calls->arg-variables exps)
      (apply
        append
        (map
          (lambda (exp)
            (cond
              ((pair? exp)
               (filter symbol? (cdr exp)))
              (else '())))
          exps)))

    ;; Does the given primitive return a new instance of an object that
    ;; can be mutated?
    ;;
    ;; TODO: strings are a problem because there are
    ;; a lot of primitives that allocate them fresh!
    (define (prim-creates-mutable-obj? prim)
      (member 
        prim
        '(cons 
          make-vector 
          make-bytevector
          bytevector bytevector-append bytevector-copy
          string->utf8 number->string symbol->string list->string utf8->string
          string-append string substring Cyc-installation-dir read-line
          Cyc-compilation-environment
          )))

    ;; Check each pair of primitive call / corresponding lambda arg,
    ;; and verify that if the primitive call creates a new mutable
    ;; object, that only one instance of the object will be created.
    (define (one-instance-of-new-mutable-obj? prim-calls lam-formals)
      (let ((calls/args (map list prim-calls lam-formals)))
        (call/cc 
          (lambda (return)
            (for-each
              (lambda (call/arg)
                (let ((call (car call/arg))
                      (arg (cadr call/arg)))
                  ;; Cannot inline prim call if the arg is used
                  ;; more than once and it creates a new mutable object,
                  ;; because otherwise if the object is mutated then
                  ;; only one of the instances will be affected.
                  (if (and (prim-call? call)
                           (prim-creates-mutable-obj? (car call))
                           ;; Make sure arg is not used more than once
                           (with-var arg (lambda (var)
                             (> (adbv:app-arg-count var) 1)))
                      )
                      (return #f))))
              calls/args)
            #t))))

    ;; Find variables passed to a primitive
    (define (prim-call->arg-variables exp)
      (filter symbol? (cdr exp)))

    ;; Helper for the next function
    (define (inline-prim-call? exp ivars args)
      (call/cc
        (lambda (return)
          (inline-ok? exp ivars args (list #f) return)
          (return #t))))

    ;; Make sure inlining a primitive call will not cause out-of-order execution
    ;; exp - expression to search
    ;; ivars - vars to be inlined
    ;; args - list of variable args (should be small)
    ;; arg-used - has a variable been used? if this is true and we find an ivar,
    ;;            it cannot be optimized-out and we have to bail.
    ;;            This is a cons "box" so it can be mutated.
    ;; return - call into this continuation to return early
    (define (inline-ok? exp ivars args arg-used return)
      ;(trace:error `(inline-ok? ,exp ,ivars ,args ,arg-used))
      (cond
        ((ref? exp)
         (cond
          ((member exp args)
           (set-car! arg-used #t))
          ((member exp ivars)
           (return #f))
          (else 
           #t)))
        ((ast:lambda? exp)
         (for-each
          (lambda (e)
            (inline-ok? e ivars args arg-used return))
          (ast:lambda-formals->list exp))
         (for-each
          (lambda (e)
            (inline-ok? e ivars args arg-used return))
          (ast:lambda-body exp)))
        ((const? exp) #t)
        ((quote? exp) #t)
        ((define? exp)
         (inline-ok? (define->var exp) ivars args arg-used return)
         (inline-ok? (define->exp exp) ivars args arg-used return))
        ((set!? exp)
         (inline-ok? (set!->var exp) ivars args arg-used return)
         (inline-ok? (set!->exp exp) ivars args arg-used return))
        ((if? exp)
          (inline-ok? (if->condition exp) ivars args arg-used return)
          (inline-ok? (if->then exp) ivars args arg-used return)
          (inline-ok? (if->else exp) ivars args arg-used return))
        ((app? exp)
         (cond
          ((and (prim? (car exp))
                (not (prim:mutates? (car exp))))
           ;; If primitive does not mutate its args, ignore if ivar is used
           (for-each
            (lambda (e)
              (if (not (ref? e))
                  (inline-ok? e ivars args arg-used return)))
            (reverse (cdr exp))))
          (else
           (for-each
            (lambda (e)
              (inline-ok? e ivars args arg-used return))
            (reverse exp))))) ;; Ensure args are examined before function
        (else
          (error `(Unexpected expression passed to inline prim check ,exp)))))


    ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    ;;  Inlining of user-defined functions
    (define (udf:inline exp)
      ;; create function table
      ;; for each top-level lambda (or any lambda??)
      ;; analyze
      ;;   might be a candiate as long as contains:
      ;;     prim calls, if, 
      ;;   immediately disregard if find any:
      ;;    - mutating prim calls (at least for now), set!, define,
      ;;    - lambda?
      ;;    - application of a variable (cannot know what happens, may
      ;;      never return)
      ;;   keep track of all functions the lambda calls
      ;; make a second pass of all potential candidates
      ;;   keep candidates only if all the functions they call are also candidates
      ;; for now return final table. may consider writing it to the meta
      ;; files so other modules can take advantage of the same inlines.
      ;; would need to generalize meta file macro support a bit though, and
      ;; add scheme base as a special case (maybe other modules, too)
      (map
        (lambda (e)
          (cons
            (define->var e) 
            (let ((rec (list (list))))
              (call/cc
                (lambda (return)
                  (for-each
                    (lambda (expr)
                      (udf:analyze 
                        expr
                        rec
                        (lambda (return-value)
                          (when (not return-value)
                            (set! rec #f)) ;; Analysis was aborted, clear rec
                          return-value)))
                    (ast:lambda-body (car (define->exp e))))))
              rec)))
        (udf:exps->lambdas exp)))

    ;; TODO: take a list of expressions and return the lambda definitions
    (define (udf:exps->lambdas exps)
      (filter
        (lambda (exp)
          (and (define? exp)
               (ast:lambda? (car (define->exp exp)))))
        exps))

    ;; Analyze a single user defined function 
    ;; exp - code to analyze
    ;; rec - analysis information for this particular function
    ;; return - function to abort early if
    (define (udf:analyze exp rec return)
      (cond
        ((ref? exp) #t)
        ((ast:lambda? exp)
         ;; TODO: could we handle certain lambdas?
         ;(return #f))
         (for-each
          (lambda (e)
            (udf:analyze e rec return))
          (ast:lambda-formals->list exp))
         (for-each
          (lambda (e)
            (udf:analyze e rec return))
          (ast:lambda-body exp)))
        ((const? exp) #t)
        ((quote? exp) #t)
        ((define? exp)
         ;; TODO: able to do more in the future?
         (return #f))
        ((set!? exp)
         (return #f))
        ((if? exp)
          (udf:analyze (if->condition exp) rec return)
          (udf:analyze (if->then exp) rec return)
          (udf:analyze (if->else exp) rec return))
        ((prim-call? exp)
         (cond
           ;; Cannot inline any function that calls into a continuation
           ((prim:cont? (car exp))
            (return #f))
           ;; At least for now, do not try to deal with mutations
           ((prim:mutates? (car exp))
            (return #f))
           (else
            (for-each
              (lambda (e)
                (udf:analyze e rec return))
              (cdr exp)))))
        ((app? exp)
         (cond
          ((ref? (car exp))
           (let ((fnc-calls (car rec)))
             (set-car! rec (cons (car exp) fnc-calls))
             (for-each
              (lambda (e)
                (udf:analyze e rec return))
              (cdr exp))))
          (else
            (map
              (lambda (e)
                (udf:analyze e rec return))
              exp))))
        (else
          (error `(Unexpected expression passed to user defined function analysis ,exp)))))
           

    ;; END user-defined function inlining
    ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

    (define (analyze-cps exp)
      (analyze exp -1) ;; Top-level is lambda ID -1
      (analyze2 exp) ;; Second pass
;; For now, beta expansion finds so few candidates it is not worth optimizing
;;      ;; TODO:
;;      ;; Find candidates for beta expansion
;;      (for-each
;;        (lambda (db-entry)
;;;(trace:error `(check for lambda candidate
;;          (cond
;;            ((number? (car db-entry))
;;             ;; TODO: this is just exploratory code, can be more efficient
;;             (let ((id (car db-entry))
;;                   (fnc (cdr db-entry))
;;                   (app-count 0)
;;                   (app-arg-count 0)
;;                   (reassigned-count 0))
;;              (for-each
;;                (lambda (sym)
;;                  (with-var! sym (lambda (var)
;;                    (set! app-count (+ app-count (adbv:app-fnc-count var)))
;;                    (set! app-arg-count (+ app-arg-count (adbv:app-arg-count var)))
;;                    (set! reassigned-count (+ reassigned-count (if (adbv:reassigned? var) 1 0)))
;;                  ))
;;                )
;;                (adbf:assigned-to-var fnc))
;;(trace:error `(candidate ,id ,app-count ,app-arg-count ,reassigned-count))
;;             ))))
;;        (hash-table->alist *adb*))
;;      ;; END TODO
    )

    ;; NOTES:
    ;;
    ;; TODO: run CPS optimization (not all of these phases may apply)
    ;; phase 1 - constant folding, function-argument expansion, beta-contraction of functions called once,
    ;;           and other "contractions". some of this is already done in previous phases. we will leave
    ;;           that alone for now
    ;; phase 2 - beta expansion
    ;; phase 3 - eta reduction
    ;; phase 4 - hoisting
    ;; phase 5 - common subexpression elimination
    ;; TODO: re-run phases again until program is stable (less than n opts made, more than r rounds performed, etc)
    ;; END notes

    ;(define (optimize-cps ast)
    ;  (define (loop ast n)
    ;    (if (= n 0)
    ;        (do-optimize-cps ast)
    ;        (loop (do-optimize-cps ast) (- n 1))))
    ;   (loop ast 2))

    (define (optimize-cps ast)
      (adb:clear!)
      (analyze-cps ast)
      (trace:info "---------------- cps analysis db:")
      (trace:info (adb:get-db))
      (opt:inline-prims 
        (opt:contract ast))
    )

))
