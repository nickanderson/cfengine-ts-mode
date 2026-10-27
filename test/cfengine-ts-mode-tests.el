;;; cfengine-ts-mode-tests.el --- Tests for cfengine-ts-mode -*- lexical-binding: t; -*-

;;; Commentary:

;; Indentation is checked against fixtures that `cfengine format' leaves
;; unchanged: strip all leading whitespace, reindent, compare.

;;; Code:

(require 'ert)
(require 'cl-lib)
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
      ;; whitespace is part of the string.  Step by line rather than
      ;; `replace-match': `syntax-ppss' runs `syntax-propertize', which
      ;; clobbers the match data.
      (while (not (eobp))
        (unless (nth 3 (syntax-ppss))
          (delete-horizontal-space t))
        (forward-line 1))
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

(ert-deftest cfengine-ts-mode-policy-file-p ()
  (cl-flet ((policy-p (file text)
              (with-temp-buffer
                (insert text)
                (goto-char (point-min))
                (let ((buffer-file-name file))
                  (and (cfengine-ts-mode-policy-file-p) t)))))
    (dolist (line '("bundle agent main"
                    "bundle agent main\r"
                    "  body common control"
                    "bundle agent main(x, y)"
                    "bundle agent main(x,"
                    "bundle agent main {"
                    "bundle agent main(x) { # comment"
                    "promise agent git"
                    "body perms m(mode)"))
      (should (policy-p "/x/promises.cf" (concat "# header\n" line "\n"))))
    (dolist (line '("# bundle agent main"
                    "bundle agent"
                    "Body Common control"
                    "BUNDLE agent main"
                    "body of the message is here"
                    "bundle agent main extra"
                    "bundle agent my.main"
                    "bundle agent ns:main"))
      (should-not (policy-p "/x/promises.cf" (concat line "\n"))))
    (should (policy-p "/x/test.cf.sub" "bundle agent main\n"))
    (should-not (policy-p "/x/main.txt" "bundle agent main\n"))
    (should (policy-p "/x/promises.cf.in" "bundle agent main\n"))
    (should (policy-p "/x/test.cf.sub.in" "bundle agent main\n"))
    (should-not (policy-p "/x/main.in" "bundle agent main\n"))
    (should-not (policy-p "/x/main.cf.bak" "bundle agent main\n"))))

;;; Activation, in a fresh Emacs that has only the generated autoloads

(defun cfengine-ts-mode-tests--fresh-emacs (grammar files)
  "Visit FILES in a fresh Emacs with this package's autoloads only.
Each element of FILES is (NAME . CONTENTS).  When GRAMMAR is nil the
grammar is hidden.  Return the printed result: a list with the
`major-mode' of each file, followed by whether the package was loaded
after visiting a non-policy file."
  (let* ((tmp (make-temp-file "cfengine-ts-mode-tests" t))
         (root (file-name-directory (directory-file-name
                                     cfengine-ts-mode-tests--dir)))
         ;; In ROOT: `loaddefs-generate' records paths relative to it.
         (loaddefs (expand-file-name "cfengine-ts-mode-autoloads.el" root))
         (paths (mapcar (lambda (f)
                          (let ((path (expand-file-name (car f) tmp)))
                            (with-temp-file path (insert (cdr f)))
                            path))
                        files))
         (form
          `(progn
             ;; Keep ~/.emacs.d/tree-sitter out of the grammar search.
             (setq user-emacs-directory ,(file-name-as-directory tmp))
             (setq treesit-extra-load-path ',(and grammar treesit-extra-load-path))
             (add-to-list 'load-path ,root)
             (load ,loaddefs nil t)
             (find-file ,(expand-file-name "notes.txt" tmp))
             (let ((loaded (featurep 'cfengine-ts-mode)))
               (prin1 (append (mapcar (lambda (f) (find-file f) major-mode)
                                      ',paths)
                              (list loaded)))))))
    (unwind-protect
        (progn
          (loaddefs-generate root loaddefs)
          (with-temp-buffer
            (should (zerop (call-process
                            (expand-file-name invocation-name
                                              invocation-directory)
                            nil t nil "-Q" "--batch"
                            "--eval" (prin1-to-string form))))
            (goto-char (point-max))
            (forward-line 0)
            (read (current-buffer))))
      (delete-file loaddefs)
      (delete-directory tmp t))))

(defconst cfengine-ts-mode-tests--postfix
  "smtpd_banner = $myhostname ESMTP\nbiff = no\n")

(defconst cfengine-ts-mode-tests--policy
  "bundle agent main\n{\n  reports:\n    \"hi\";\n}\n")

(ert-deftest cfengine-ts-mode-activates-from-autoloads ()
  (skip-unless (treesit-ready-p 'cfengine t))
  (should (equal (cfengine-ts-mode-tests--fresh-emacs
                  t `(("promises.cf" . ,cfengine-ts-mode-tests--policy)
                      ("test.cf.sub" . ,cfengine-ts-mode-tests--policy)
                      ("main.cf" . ,cfengine-ts-mode-tests--postfix)))
                 ;; Visiting notes.txt must not load the package.
                 '(cfengine-ts-mode cfengine-ts-mode conf-unix-mode nil))))

(ert-deftest cfengine-ts-mode-falls-back-without-grammar ()
  (should (equal (cfengine-ts-mode-tests--fresh-emacs
                  nil `(("promises.cf" . ,cfengine-ts-mode-tests--policy)))
                 '(cfengine3-mode nil))))

;;; Completion and ElDoc (from cfengine.el)

(ert-deftest cfengine-ts-mode-completes-functions ()
  (with-temp-buffer
    (cfengine-ts-mode)
    (insert "isvar")
    (let ((capf (cfengine-ts-mode--completion-at-point)))
      (should (equal (all-completions
                      (buffer-substring (nth 0 capf) (nth 1 capf))
                      (nth 2 capf))
                     '("isvariable")))
      (should (eq (plist-get (nthcdr 3 capf) :exclusive) 'no)))))

;; cfengine.el falls back to built-in syntax data without cf-promises.
(ert-deftest cfengine-ts-mode-completes-without-cf-promises ()
  (let ((cfengine-cf-promises nil)
        (cfengine-mode-syntax-cache nil))
    (with-temp-buffer
      (cfengine-ts-mode)
      (insert "isvar")
      (should (member "isvariable"
                      (all-completions
                       "isvar" (nth 2 (cfengine-ts-mode--completion-at-point))))))))

(ert-deftest cfengine-ts-mode-eldoc-signature ()
  (cfengine-ts-mode-tests--with-fixture "indent.cf"
    (search-forward "join(")
    (should (memq #'cfengine3-documentation-function
                  eldoc-documentation-functions))
    (should (string-match-p "\\`string join("
                            (cfengine3-documentation-function)))))

(provide 'cfengine-ts-mode-tests)
;;; cfengine-ts-mode-tests.el ends here
