;;; -*- Mode: LISP; Syntax: Common-lisp; Package: CLIMAX; Base: 10 -*-
;;;>******************************************************************************************
;;;>   Software developed by Bruce R. Miller
;;;>   using Symbolics Common Lisp (system 425.111, ivory revision 4)
;;;>   at NIST - Computing and Applied Mathematics Laboratory
;;;>   a part of the U.S. Government; it is therefore not subject to copyright.
;;;>******************************************************************************************

(in-package 'climax)

;;; To run in Schelter's Maxima comment the above and uncomment these:
;(in-package 'maxima)
;(defmacro mexp-lookup (item alist) `(assolike ,item ,alist))
;(defmacro mlist* (arg1 &rest more-args) `(list* '(mlist simp) ,arg1 ,@more-args))

;;;;******************************************************************************************
;;;; Needed, but unrelated, stuff.  Possibly useful in its own right
;;;;******************************************************************************************
;;; Returns an mlist of all subexpressions of expr which `match' predicate.
;;; Predicate(expr,args,...) returns non-nil if the expression matches.
;;; [eg. a function constructed by $defmatch]
(defun $matching_parts (expr predicate &rest args)
  (let ((matches nil))
    (labels ((srch (expr)
	       (when (specrepp expr)
		 (setq expr (specdisrep expr)))
	       (when (apply #'mfuncall predicate expr args)
		 (pushnew expr matches :test #'alike1))
	       (unless (atom expr)
		 (mapc #'srch (cdr expr)))))
      (srch expr)
      (mlist* matches))))

;;; Return an  mlist of all unique function calls of the function(s) FCNS in EXPR.
;;; (FCNS can also be a single function)
(defun $function_calls (expr &rest functions)
  ;; Coerce fcns to a list of function names.
  (let ((fcns (mapcar #'(lambda (x)(or (get (setq x (getopr x)) 'verb) x)) functions)))
    ($matching_parts expr #'(lambda (p)(and (listp p)(member (caar p) fcns))))))

;;; Return an mlist of all unique arguments used by FCNS in EXPR.
(defun $function_arguments (expr &rest functions)
  (mlist* (remove-duplicates (cdr (map1 #'$args (apply #'$function_calls expr functions)))
			     :test #'alike1)))

;;; $totaldisrep only `disrep's CRE (mrat), but not POIS!
(defun totalspecdisrep (expr)
  (cond ((atom expr) expr)
	((not (or (among 'mrat expr)(among 'mpois expr))) expr)
	((eq (caar expr) 'mrat)(ratdisrep expr))
	((eq (caar expr) 'mpois) ($outofpois expr))
	(t (cons (remove 'ratsimp (car expr))(mapcar 'totalspecdisrep (cdr expr))))))

;;;;******************************************************************************************
;;;; Variable Lists
;;; A variable list consists of a list of variables, simple expressions and specs like
;;;   OPERATOR(fcn) or OPERATOR(fcn,...) represents ALL calls to fcn in the expression.
;;;   MATCH(fcn,arg..) represents subexpressions of expression which pass FCN(subexpr,args..)
;;; Instanciating the variable list involves replacing those special cases with those
;;; subexpressions of the relevant expression which pass the test.
;;;;******************************************************************************************

(defun instanciate-variable-list (vars expr caller &optional max-vars)
  (let ((ivars (mapcan #'(lambda (var)
			   (setq var (totalspecdisrep var))
			   (case (and (listp var)(caar var))
			     ($operator (cdr (apply #'$function_calls expr (cdr var))))
			     ($match    (cdr (apply #'$matching_parts expr (cdr var))))
			     (t (list var))))
		       vars)))
    (when (and max-vars (> (length ivars) max-vars))
      (merror "Too many variables for ~M: ~M" caller (mlist* ivars)))
    ivars))

;;;;******************************************************************************************
;;;; Helpers
;;;;******************************************************************************************

;;; Similar to lisp:reduce with the :key keyword.
;;; Apparently, the Lisp underneath the Sun version doesn't support it. Ugh.
;  (defmacro cl-reduce (function list key) `(lisp:reduce ,function ,list :key ,key))

(defun cl-reduce (function list key)
  (if (null list) nil
      (let ((result (funcall key (car list))))
	(dolist (item (cdr list))
	  (setq result (funcall function result (funcall key item))))
	result)))

(defun map-mlist (list) (mapcar #'(lambda (e)(mlist* e)) list))

;;;******************************************************************************************
;;; Coefficient List = Pseudo-polynomial : as list of ( (coefficient power(s) ...) ...)
;;;     coefficient: the coefficient of the monomial (anything algebraic thing)
;;;     power(s) : the power(s) of the variable(s) in the monomial (any algebraic thing)
;;; Pairs are sorted into increasing order of the power(s).   
;;; 0 is represented by NIL.
;;;******************************************************************************************
;;; NOTE on ordering of terms.  The Macsyma predicate GREAT (& friends lessthan, etc)
;;; define a total ordering, but if non-numeric elements are allowed, the ordering is not
;;; robust under addition, eg L=[1,2,m] is in order, but L+m=[m,m+2,2*m] is not.
;;; We define the ordering of A & B by determining the `sign' of A-B, where the sign is
;;; the sign of the coefficient of the leading (highest degree) term.  We can use SIGNUM1 
;;; for this. 
;;;******************************************************************************************

;;;******************************************************************************************
;;; CLIST Arithmetic

;;; Add two CLISTs
(defun clist-add (l1 l2)
  (do ((result nil))
      ((not (and l1 l2)) (if (or l1 l2)(nconc (nreverse result)(or l1 l2)) (nreverse result)))
    (do ((p1 (cdar l1) (cdr p1))
	 (p2 (cdar l2) (cdr p2)))
	((or (null p1) (not (alike1 (car p1)(car p2))))
	 (if p1
	     (push (if (plusp (signum1 (sub (car p1)(car p2))))(pop l2)(pop l1)) result)
	     (let ((c3 (add (caar l1)(caar l2))))	;If power is same, combine
	       (unless (zerop1 c3)		;And accumulate result, unless zero.
		 (push (cons c3 (cdar l1)) result))
	       (pop l1)(pop l2)))))))

;;; Multiply two CLISTs
;;; Optional ORDER is for use by series arithmetic (single variable): truncates powers>order
(defun clist-mul (l1 l2 &optional order)
  (when (and l1 l2)
    (when (> (length l1)(length l2))		; make l1 be shortest
      (psetq l1 l2 l2 l1))
    (let ((rl2 (reverse l2)))
      (flet ((mul1 (pair1)
	       (let ((c1 (car pair1)) (p1 (cdr pair1)) result)
		 (dolist (i2 rl2)
		   (let ((p (mapcar #'add p1 (cdr i2))))
		     (unless (and order (great (car p) order))
		       (push (cons (mul c1 (car i2)) p) result))))
		 result)))
 	(cl-reduce #'clist-add l1 #'mul1)))))

;;; Take the Nth power of a CLIST, using "binary expansion of the exponent" method.
;;; Built-in code to handle P^2, instead of P*P.
(defun clist-pow (l n)				; Assumes n>0
  (cond ((null l) nil)				; l=0 -> 0 (nil)
	((null (cdr l))				; single term, trivial
	 `((,(power (caar l) n) ,@(mapcar #'(lambda (p)($expand (mul p n)))(cdar l)))))
	(t (let ((l^i l) (l^n (if (logtest n 1) l)))
	     (do ((bits (lsh n -1)(lsh bits -1)))
		 ((zerop bits) l^n)
	       (do ((sq nil)			; Square l^i
		    (ll (reverse l^i) (cdr ll)))
		   ((null ll) (setq l^i sq))
		 (let* ((c1 (caar ll)) (2c1 (mul 2 c1))(p1 (cdar ll))
			(psq (list (cons (power c1 2)(mapcar #'add p1 p1)))))
		   (dolist (lll (cdr ll))
		     (push (cons (mul 2c1 (car lll))(mapcar #'add p1 (cdr lll))) psq))
		   (setq sq (if sq (clist-add sq psq) psq))))
	       (if (logtest bits 1) (setq l^n (if l^n (clist-mul l^n l^i) l^i))))))))

;;; An MBAG includes lists, arrays and equations.
;;; Given the list of {list|array|equation} elements which have been converted to CLIST's, 
;;; this function combines them into a single clist whose coefficients 
;;; are {list|array|equation}s

(defun clist-mbag (op clists)
  (let ((z (if (eq op '$MATRIX)			; the `zero' of a matrix is an mlist of 0's!!!
	       (mlist* (make-list (length (cdaaar clists)) :initial-element 0))
	       0)))
    (flet ((keylessp (l1 l2)			; does key l1 precede l2?
	     (do ((l1 l1 (cdr l1))
		  (l2 l2 (cdr l2)))
		 ((or (null l1)(not (alike1 (car l1)(car l2))))
		  (and l1 (minusp (signum1 (sub (car l1)(car l2)))))))))
      (mapcar #'(lambda (p)
		  `(((,op)
		     ,@(mapcar #'(lambda (l)(or (car (rassoc p l :test #'alike)) z)) clists))
		    ,@p))
	      (sort (cl-reduce #'union1 clists #'(lambda (e)(mapcar #'cdr e))) #'keylessp)))))

;;;;******************************************************************************************
;;;; Transform an expression into its polynomial coefficient list form.

(defun $coeffs (expr &rest vars)
  (setq expr (totalspecdisrep expr))
  (let* ((vs (instanciate-variable-list vars expr '$coeffs))
	 (zeros (make-list (length vs) :initial-element 0))
	 (cache nil))
    (dolist (v vs)				; preload the cache w/ encoded variables
      (let ((u (copy-list zeros)))
	(setf (nth (position v vs) u) 1)
	(push (cons v (list (cons 1 u))) cache)))
    (labels ((gcf (expr)			; Get coefficients.
	       (or (mexp-lookup expr cache)	; reuse cached value
		   (cdar (push (cons expr (gcf1 expr)) cache))))	; or compute & store
	     (gcf1 (expr)
	       (let ((op (and (listp expr)(caar expr))) x y)
		 (cond ((MBAGp expr)    (clist-mbag op (mapcar #'gcf (cdr expr))))
		       ((or (null op)(not (dependsall expr vs))) `((,expr . ,zeros)))
		       ((eq op 'MPLUS)  (cl-reduce #'clist-add (cdr expr) #'gcf))
		       ((eq op 'MTIMES) (cl-reduce #'clist-mul (cdr expr) #'gcf))
		       ((and (eq op 'MEXPT)	; Check that we can actually compute X^Y:
			     (setq x (gcf (second expr)) y (third expr))
			     (or (and (integerp y)(plusp y))	; Either integer y > 0
				 (and (null (cdr x))	; or x is a single monomial
				      (not (dependsall y vs))	; w/ y must be free of vars
				      (or (eql $RADEXPAND '$ALL) ; & dont care about cuts
					  (integerp y)	; or y is an integer
					  (every #'(lambda (p)(or (zerop1 p)(onep p)))
						 (cdar x))))))	; or x is linear in vars.
			(clist-pow x y))	; OK, so we CAN compute x^y (whew).
		       (t `((,expr . ,zeros)))))))
      (mlist* (mlist* '$%POLY vs)(map-mlist (gcf expr))))))

; Inverse of above: make an expression out of clist.
;;; Actually works for SERIES & Taylor too.
(defun unclist (clist vars)
  (addn (mapcar #'(lambda (e)(mul (cadr e)(muln (mapcar #'power vars (cddr e)) t))) clist) t))

;;;********************************************************************************
;;; TRIG SERIES
;;; Given an expression and a list of variables, v_i, construct the list of sine & cosine
;;; coefficients & multiples of the variables in the expression:
;;;  [[%trig, v_1, ...] sine_list, cosine_list]
;;;     sine_list: [[c,m_1,...],[c',m_1',...]....]
;;;     cosine_list: " "
;;;
;;; Use POISSON Series facilities to contruct coefficient list.
;;;  1) Find maximum multiples for each variable and ensure that the poisson series
;;;     parameters can accomodate the expression.
;;;  2) use INTOPOIS to convert to POISSON representation.
;;;  3) walk the poisson form constructing the list of coefficients & multipliers.
;;;********************************************************************************

;;; The declaration inside SHOULD be enough, but AKCL apparently doesn't handle it correctly
(proclaim '(special $poisvars $poislim $pois_encode_liberalize 
		    *pois-encoding* poishift *pois-guard* *poisz* *pois1*))

(defun $trig_coeffs (expr &rest vars)
  (unless (or (fboundp '$intopois) (mfboundp '$intopois))	; Is this the `Right Way'?
    (load-function '$intopois nil))
  (setq expr (totalspecdisrep expr))
  (let* ((vars (instanciate-variable-list vars expr '$trig_coeffs))
	 ($poisvars (mlist* vars))($poislim nil)($pois_encode_liberalize t)
	 *pois-encoding* poishift *pois-guard* *poisz* *pois1*)
    (declare (special $poisvars $poislim $pois_encode_liberalize 
		      *pois-encoding* poishift *pois-guard* *poisz* *pois1*))
    (unless (dependsall expr vars)
      (return-from $trig_coeffs
	(mlist* (mlist* '$%TRIG vars)'((mlist))
		(mlist* (mlist* expr (mapcar #'(lambda (v) 0) vars)) nil) nil)))
    (pois-setup $poisvars $poislim)
    (flet ((make1 (pairs)
	     (do ((p pairs (cddr p))
		  (l nil))
		 ((null p) (nreverse l))
	       (push (cons (poiscdecode (cadr p)) (poisarg-unpack (car p))) l))))
      (labels ((makem (expr)
		 (if (mbagp expr)
		     (let ((elements (mapcar #'makem (cdr expr))))
		       (list (clist-mbag (caar expr) (mapcar #'car elements))
			     (clist-mbag (caar expr) (mapcar #'cadr elements))))
		     (let ((pois (intopois expr)))
		       (list (make1 (cadr pois)) (make1 (caddr pois)))))))
	(let ((trig (makem expr)))
	  (mlist* (mlist* '$%TRIG vars)
		  (mlist* (map-mlist (car trig)))(mlist* (map-mlist (cadr trig))) nil))))))

(defun untlist (tlist vars)
  (flet ((un1 (list trig)
	   (flet ((un2 (e)(mul (cadr e)(cons-exp trig (multl (cddr e) vars)))))
	     (addn (mapcar #'un2 list) t))))
    (addn (mapcar #'un1 tlist '(%sin %cos)) t)))

;;;********************************************************************************
;;; SERIES & TAYLOR
;;; Given an expression, a variable and an order, compute the coefficients of the
;;; expansion of the expression about variable=0 to order ORDER.
;;;  -> [[%series,variable,order],[c,p],[c',p'],...]
;;;  or [[%taylor,variable,order],[c,p],[c',p'],...]
;;; The difference is that TAYLOR computes the Taylor expansion, whereas
;;; SERIES only carries out the expansion over arithmetic functions (+,*,exp) and thus 
;;; is significantly faster.
;;;********************************************************************************

(defun $taylor_coeffs (expr var order)
  (setq expr (totalspecdisrep expr))
  (let ((var (car (instanciate-variable-list (list var) expr '$taylor_coeffs 1))))
    (labels ((make1 (expr)
	       (cond ((mbagp expr)      (clist-mbag (caar expr) (mapcar #'make1 (cdr expr))))
		     ((freeof var expr) (list (list expr 0)))
		     (t (let* ((r ($taylor expr var 0 order))
			       (ohdr (car r))
			       (hdr (list (first ohdr)(second ohdr)(third ohdr)(fourth ohdr))))
			  (if (eq (second r) 'ps)
			      (mapcar #'(lambda (p)
					  (list (specdisrep (cons hdr (cdr p)))
						(cons-exp 'rat (caar p)(cdar p))))
				      (cddddr r))
			      (list (list (specdisrep (cons hdr (cdr r))) 0))))))))
      (mlist* (mlist* '$%TAYLOR var order nil)(map-mlist (make1 expr))))))

;;;;******************************************************************************************
;;;; SLIST Arithmetic.
;;; The addition & multiplication of polynomial arithmetic are used.

;;; compute the N-th power of S through ORDER.
(defun slist-pow (s n order)
  (when s
    (let* ((m (cadar s))
	   (nm (mul n m))
	   (s_m (caar s))
	   (p (list (list (power s_m n) nm))))	; 1st term of result
      (if (null (cdr s))			; Single term
	  (or (great nm order) p)		; then trivial single term (unless high order)
	  (let* ((g (cl-reduce #'$gcd s #'(lambda (x)(sub (cadr x) m))))
		 (kmax (div (sub order nm) g)))
	    (do ((k 1 (1+ k)))
		((great k kmax) (nreverse p))
	      (let ((ff (div (add 1 n) k))
		    (trms nil))
		(dolist (s (cdr s))
		  (let ((i (div (sub (cadr s) m) g)))
		    (when (lessthan k i)(return))
		    (let ((e (member (add nm (mul (sub k i) g)) p :key #'cadr :test #'like)))
		      (when e			; multthru limits expression depth
 			(push ($multthru (mul (sub (mul i ff) 1) (car s) (caar e))) trms)))))
		(let ((pk ($multthru (div (addn trms t) s_m))))
		  (unless (zerop1 pk)
		    (push (list pk (add nm (mul k g))) p))))))))))

;;;;******************************************************************************************
;;;; Extracting Series Coefficients.

(defun $series_coeffs (expr var order)
  (setq expr (totalspecdisrep expr))
  (let ((v (car (instanciate-variable-list (list var) expr '$series_coeffs 1))))
    (setq v ($ratdisrep v))
    (labels ((mino (expr)			; Find minumum power of V in expr (for mult)
	       (let ((op (and (listp expr)(caar expr))))
		 (cond ((like expr v)   1)	; Trivial case: expr is V itself
		       ((or ($atom expr)(freeof v expr)) 0)	; `constant' case
		       ((member op '(MPLUS MLIST MEQUAL $MATRIX))
			(cl-reduce #'$min (cdr expr) #'mino))
		       ((eq op 'MTIMES)  (cl-reduce #'add (cdr expr) #'mino))
		       ((and (eq op 'MEXPT)($numberp (third expr)))	; can we compute?
			(mul (mino (second expr)) (third expr)))
		       (t 0))))			; oh, well, Treat it as constant.
	     (gcf (expr order)
	       (let ((op (and (listp expr)(caar expr))))
		 (cond ((like expr v)   `((1 1)))	; Trivial case: expr is V itself
		       ((or ($atom expr)(freeof v expr)) `((,expr 0)))	; `constant' case
		       ((MBAGp expr)
			(clist-mbag op (mapcar #'(lambda (el)(gcf el order))(cdr expr))))
		       ((eq op 'MPLUS)
			(cl-reduce #'clist-add (cdr expr) #'(lambda (el)(gcf el order))))
		       ((eq op 'MTIMES)
			(let* ((ms (mapcar #'mino (cdr expr)))
			       (mtot (addn ms t))
			       (prod '((1 0))))
			  (unless (great mtot order)
			    (do ((terms (cdr expr)(cdr terms))
				 (m ms (cdr m)))
				((null terms) prod)
			      (let ((term (gcf (car terms) (sub (add order (car m)) mtot))))
				(setq prod (clist-mul term prod order)))))))
		       ((and (eq op 'MEXPT)($numberp (third expr)))	; can we compute?
			(slist-pow (gcf (second expr) order)(third expr) order))
		       (t `((,expr 0)))))))	; just treat it as constant.
      (mlist* (mlist* '$%SERIES v order nil)(map-mlist (gcf expr order))))))

(defun unslist (clist vars)
  ($trunc (unclist clist vars)))

;;;********************************************************************************
;;; Find the coefficient associated with keys (powers or multiples) in the 
;;; coefficient list clist.
(defun $get_coef (clist &rest keys)
  (let ((sublist (case (and ($listp clist)($listp (cadr clist))(cadr (cadr clist)))
		   (($%POLY $%SERIES $%TAYLOR) (cddr clist))
		   ($%TRIG (case (car keys)
			     (($SIN %SIN) (cdr (third clist)))
			     (($COS %COS) (cdr (fourth clist)))
			     (otherwise (merror "First KEY must be SIN or COS"))))
		   (otherwise (merror "Unknown coefficient list type: ~M" clist)))))
    (or (cadar (member keys sublist :test #'alike :key #'cddr)) 0)))

;;; Reconstruct a macsyma expression from a coefficient list.
(defun $uncoef (cl)
  (let ((spec (and ($listp cl)(second cl))))
    (case (and ($listp spec)(second spec))
      ($%POLY  (unclist (cddr cl) (cddr spec)))
      (($%SERIES $%TAYLOR) (unslist (cddr cl) (cddr spec)))
      ($%TRIG   (untlist (mapcar #'cdr (cddr cl)) (cddr spec)))
      (otherwise (merror "UNCOEF: Unrecognized COEFFS form: ~M" cl)))))

;;;********************************************************************************
;;; Partition a polynomial, trig series or series into those terms whose 
;;; powers (or multiples) pass a certain test, and those who dont.
;;; Returns the pair [passed, failed].
;;; The TEST is applied to the exponents or multiples of each term.

(defun partition-clist (list test)
  (cond ((null test) (values nil list))
	((eq test T) (values list nil))
	(t  (let ((pass nil)(fail nil))
	      (dolist (item list)
		(if (is-boole-check (mapply test (cddr item) '$partition_test))
		    (push item pass)
		    (push item fail)))
	      (values (nreverse pass)(nreverse fail))))))

(defun $partition_poly (expr test &rest vars)
  (let* ((clist (apply #'$coeffs expr vars))
	 (vars (cddr (second clist))))
    (multiple-value-bind (p f)(partition-clist (cddr clist) test)
      (mlist* (unclist p vars)(unclist f vars) nil))))

(defun $partition_trig (expr sintest costest &rest vars)
  (let* ((tlist (apply #'$trig_coeffs expr vars))
	 (vars (cddr (second tlist))))
    (multiple-value-bind (sp sf)(partition-clist (cdr (third tlist)) sintest)
      (multiple-value-bind (cp cf)(partition-clist (cdr (fourth tlist)) costest)
	(mlist* (untlist (list sp cp) vars) (untlist (list sf cf) vars) nil)))))

(defun $partition_series (expr test var order)
  (let* ((clist ($series_coeffs expr var order))
	 (var (caddr (second clist))))
    (multiple-value-bind (p f)(partition-clist (cddr clist) test)
      (mlist* (unslist p var)(unslist f var) nil))))

(defun $partition_taylor (expr test var order)
  (let* ((clist ($taylor_coeffs expr var order))
	 (var (caddr (second clist))))
    (multiple-value-bind (p f)(partition-clist (cddr clist) test)
      (mlist* (unslist p var)(unslist f var) nil))))