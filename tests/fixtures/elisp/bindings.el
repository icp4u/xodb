;;; -*- lexical-binding: t; -*-
(require 'json)
(defvar xodb-dynamic 0)
(defun xodb-binding-mark ()
  (let ((level 1) (rows nil) entry)
    (while (setq entry (backtrace-frame level 'xodb-binding-mark))
      ;; backtrace--locals includes the whole saved environment. This fixture
      ;; knows which names each source form introduces; their values still
      ;; come from Emacs's own backtrace oracle.
      (let* ((locals (backtrace--locals level 'xodb-binding-mark))
             (introduced (pcase level
                           (1 '(xodb-dynamic xodb-child-local))
                           (2 '(xodb-child-arg))
                           (3 '(xodb-dynamic xodb-parent-local))
                           (4 '(xodb-parent-arg)))))
        (dolist (name introduced)
          (unless (assq name locals) (error "Missing fixture binding: %s" name)))
        (push `((level . ,level)
                (name . ,(format "%s" (nth 1 entry)))
                (bindings . ,(vconcat
                              (delq nil (mapcar
                                         (lambda (cell)
                                           (when (memq (car cell) introduced)
                                             (vector (symbol-name (car cell)) (prin1-to-string (cdr cell)))))
                                         locals)))))
              rows))
      (setq level (1+ level)))
    (let ((coding-system-for-write 'utf-8-unix))
      (with-temp-file (getenv "XODB_ELISP_ORACLE")
        (insert (json-encode (vconcat (nreverse rows)))))))
  (debugger-trap))
(defun xodb-binding-child (xodb-child-arg)
  (let ((xodb-dynamic 22) (xodb-child-local "child"))
    (setq xodb-dynamic 23)
    (xodb-binding-mark)))
(defun xodb-binding-parent (xodb-parent-arg)
  (let ((xodb-dynamic 11) (xodb-parent-local "parent"))
    (xodb-binding-child 42)))
(xodb-binding-parent 17)
