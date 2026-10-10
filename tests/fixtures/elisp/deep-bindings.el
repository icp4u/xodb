;;; -*- lexical-binding: t; -*-
;; Owned stack-cap and preview-budget fixture; no user configuration.
(defvar xodb-depth 0)
(defvar xodb-cleanup 0)
(setq max-lisp-eval-depth 10000)
(defun xodb-deep (n)
  (let ((xodb-depth n) (xodb-token (format "level-%d" n)))
    (condition-case problem
        (unwind-protect
            (if (> n 0) (xodb-deep (1- n)) (debugger-trap))
          (setq xodb-cleanup n))
      (error (signal (car problem) (cdr problem))))))
(defun xodb-budget-mark () (debugger-trap))
(unless (equal (getenv "XODB_ELISP_LIMIT_CASE") "budget") (xodb-deep 300))
(unless (equal (getenv "XODB_ELISP_LIMIT_CASE") "deep")
  (let ((payload (vconcat (make-list 24 (make-list 24 (make-string 300 ?x)))))
        (bindings nil))
    (dotimes (index 32)
      (push (list (intern (format "xodb-budget-%02d" index)) (list 'quote payload)) bindings))
    (eval (list 'let (nreverse bindings) '(xodb-budget-mark)) t)))
(princ "deep bindings: done\n")
