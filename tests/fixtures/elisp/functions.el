;;; -*- lexical-binding: t; -*-
(defvar xodb-elisp-dynamic nil)
(defvar xodb-elisp-cleanup nil)
(defun xodb-elisp-inner (number text)
  (let ((xodb-elisp-dynamic (list number text)))
    (condition-case err
        (unwind-protect (xodb-elisp-mark number text xodb-elisp-dynamic)
          (setq xodb-elisp-cleanup t))
      (error (signal (car err) (cdr err))))))
(defun xodb-elisp-outer (number text)
  (xodb-elisp-inner number text))
