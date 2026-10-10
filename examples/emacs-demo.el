;;; emacs-demo.el --- JSON tasks into an Org-style outline -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defvar demo-stage "idle")

(defun xodb-demo-checkpoint (label)
  "Stop at a native marker while LABEL and its callers remain visible."
  (debugger-trap))

(cl-defun xodb-demo-summary (json-text &key (prefix "TODO"))
  "Render JSON tasks, keeping interpreter locals visible at each checkpoint."
  (let* ((demo-stage "normalize")
         (records (json-parse-string json-text
                                             :object-type 'alist :array-type 'list))
         (count (length records))
         (total 0))
    (condition-case problem
        (let ((lines
               (mapcar
                (lambda (item)
                  (let ((title (alist-get 'title item))
                        (points (alist-get 'points item)))
                    (unless (integerp points)
                      (error "Task points must be an integer"))
                    (setq total (+ total points))
                    (xodb-demo-checkpoint "item")
                    (format "* %s %s [%d]" prefix
                            (upcase title) points)))
                records)))
          (let ((demo-stage "render"))
            (xodb-demo-checkpoint "render")
            (format "%s\nTotal: %d tasks / %d points\n"
                    (string-join lines "\n") count total)))
      (error
       (xodb-demo-checkpoint "error")
       (format "Rejected: %s\n" (error-message-string problem))))))

(princ (xodb-demo-summary
        "[{\"title\":\"Profile delta\",\"points\":2},{\"title\":\"Cache budget\",\"points\":3}]"))
(princ (xodb-demo-summary "[{\"title\":\"Bad estimate\",\"points\":\"unknown\"}]"))
