;;; cfengine-ts-mode-tests.el --- Tests for cfengine-ts-mode -*- lexical-binding: t; -*-

;;; Commentary:

;; Indentation is checked against fixtures that `cfengine format' leaves
;; unchanged: strip all leading whitespace, reindent, compare.

;;; Code:

(require 'ert)
(require 'cfengine-ts-mode)

(defconst cfengine-ts-mode-tests--dir
  (file-name-directory (or load-file-name buffer-file-name)))

(defmacro cfengine-ts-mode-tests--with-fixture (file &rest body)
  "Run BODY in a `cfengine-ts-mode' buffer holding fixture FILE."
  (declare (indent 1))
  `(with-temp-buffer
     (insert-file-contents (expand-file-name ,file cfengine-ts-mode-tests--dir))
     (cfengine-ts-mode)
     ,@body))

(ert-deftest cfengine-ts-mode-grammar-available ()
  (should (treesit-ready-p 'cfengine t)))

(ert-deftest cfengine-ts-mode-indent-matches-cfengine-format ()
  (skip-unless (treesit-ready-p 'cfengine t))
  (cfengine-ts-mode-tests--with-fixture "indent.cf"
    (let ((expected (buffer-string)))
      (goto-char (point-min))
      ;; Leave multi-line string continuations alone; their leading
      ;; whitespace is part of the string.
      (while (re-search-forward "^[ \t]+" nil t)
        (unless (nth 3 (syntax-ppss (match-beginning 0)))
          (replace-match "")))
      (indent-region (point-min) (point-max))
      (should (equal (buffer-string) expected)))))

(ert-deftest cfengine-ts-mode-no-parse-errors ()
  (skip-unless (treesit-ready-p 'cfengine t))
  (cfengine-ts-mode-tests--with-fixture "indent.cf"
    (should-not (treesit-node-check (treesit-buffer-root-node) 'has-error))))

(ert-deftest cfengine-ts-mode-imenu ()
  (skip-unless (treesit-ready-p 'cfengine t))
  (cfengine-ts-mode-tests--with-fixture "indent.cf"
    (let ((index (treesit-simple-imenu)))
      (should (equal (mapcar #'car (cdr (assoc "Bundle" index)))
                     '("main" "helper")))
      (should (equal (mapcar #'car (cdr (assoc "Body" index)))
                     '("control" "m"))))))

(ert-deftest cfengine-ts-mode-fontifies-variables-in-strings ()
  (skip-unless (treesit-ready-p 'cfengine t))
  (cfengine-ts-mode-tests--with-fixture "indent.cf"
    (font-lock-ensure)
    (goto-char (point-min))
    (search-forward "$(param)")
    (let ((face (get-text-property (match-beginning 0) 'face)))
      (should (memq 'font-lock-variable-use-face (ensure-list face))))))

(provide 'cfengine-ts-mode-tests)
;;; cfengine-ts-mode-tests.el ends here
