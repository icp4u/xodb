;;; -*- lexical-binding: t; -*-
(require 'comp)
(setq native-comp-speed 0 native-comp-debug 3 byte-compile-warnings nil)
(let ((source (getenv "XODB_ELISP_SOURCE")) (output (getenv "XODB_ELISP_NATIVE")))
  (unless (byte-compile-file source) (error "Byte compilation failed"))
  (native-compile source output))
