;;; -*- lexical-binding: t; -*-
(require 'json)
(defun xodb-elisp-mark (number text dynamic)
  (when (getenv "XODB_ELISP_REDEFINE")
    (fset 'xodb-elisp-inner
          (if (equal (getenv "XODB_ELISP_REDEFINE") "bytecode")
              (byte-compile (lambda (&rest _args) :replacement))
            (lambda (&rest _args) :replacement))))
  (let* ((frames (backtrace-frames 'xodb-elisp-mark))
         (ours (mapcar
                 (lambda (f)
                   (list :name (if (symbolp (nth 1 f)) (symbol-name (nth 1 f)) "<function object>")
                         :nargs (if (car f) (length (nth 2 f)) -1))) frames)))
    (with-temp-file (getenv "XODB_ELISP_ORACLE")
      (insert (json-serialize
               (list :mode (getenv "XODB_ELISP_MODE") :version emacs-version
                     :frames (vconcat ours) :active-kind xodb-elisp-active-kind
                     :number number :text text
                     :dynamic (prin1-to-string dynamic)
                     :current-definition (cond
                                          ((native-comp-function-p (symbol-function 'xodb-elisp-inner)) "native")
                                          ((byte-code-function-p (symbol-function 'xodb-elisp-inner)) "bytecode")
                                          (t "interpreted"))))))
    (debugger-trap)))
(load (getenv "XODB_ELISP_FUNCTIONS") nil nil t)
(defvar xodb-elisp-active-kind
  (let ((f (symbol-function 'xodb-elisp-inner)))
    (cond ((native-comp-function-p f) "native")
          ((byte-code-function-p f) "bytecode")
          (t "interpreted"))))
(dotimes (_ (string-to-number (or (getenv "XODB_ELISP_REPEATS") "1")))
  (xodb-elisp-outer -17 "sample"))
(unless xodb-elisp-cleanup (error "Owned unwind cleanup did not execute"))
