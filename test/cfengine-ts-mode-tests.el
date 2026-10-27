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
                     '("main" "helper" "trailing")))
      (should (equal (mapcar #'car (cdr (assoc "Body" index)))
                     '("control" "m" "control"))))))

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

;;; Formatting

(defmacro cfengine-ts-mode-tests--with-cli (&rest body)
  "Run BODY if the CFEngine CLI is installed, else skip."
  (declare (indent 0))
  `(progn
     (skip-unless (executable-find cfengine-ts-mode-cfengine-program))
     ,@body))

(ert-deftest cfengine-ts-mode-format-buffer ()
  (cfengine-ts-mode-tests--with-cli
    (with-temp-buffer
      (insert "bundle agent main\n{\nvars:\n\"x\"   string => \"a\";\n}\n")
      (cfengine-ts-mode)
      (goto-char (point-min))
      (search-forward "string")
      (cfengine-ts-mode-format-buffer)
      (should (equal (buffer-string)
                     "bundle agent main\n{\n  vars:\n    \"x\" string => \"a\";\n}\n"))
      ;; Point stays on the same word.
      (should (looking-back "string" (line-beginning-position))))))

(ert-deftest cfengine-ts-mode-format-buffer-leaves-broken-policy-alone ()
  (cfengine-ts-mode-tests--with-cli
    (with-temp-buffer
      (let ((broken "bundle agent main\n{\n  vars:\n    \"x\" string => {{ \"a\";\n"))
        (insert broken)
        (cfengine-ts-mode)
        (should-error (cfengine-ts-mode-format-buffer) :type 'user-error)
        (should (equal (buffer-string) broken))
        ;; Formatting on save reports the failure instead of blocking.
        (let ((cfengine-ts-mode-format-on-save t))
          (cfengine-ts-mode--format-before-save))
        (should (equal (buffer-string) broken))))))

(defconst cfengine-ts-mode-tests--three-blocks
  (concat "# header\n"
          "bundle agent one\n{\nvars:\n\"a\"   string => \"1\";\n}\n"
          "\n# between\n"
          "bundle agent two\n{\nvars:\n\"b\"   string => \"2\";\n}\n"
          "\n"
          "bundle agent three\n{\nvars:\n\"c\"   string => \"3\";\n}\n"))

(defun cfengine-ts-mode-tests--block (n)
  "Return bundle N, messy or formatted, as in the three-blocks policy."
  (format "bundle agent %s\n{\n  vars:\n    \"%s\" string => \"%d\";\n}"
          (nth (1- n) '("one" "two" "three")) (nth (1- n) '("a" "b" "c")) n))

(ert-deftest cfengine-ts-mode-format-region-whole-blocks ()
  (cfengine-ts-mode-tests--with-cli
    (with-temp-buffer
      (insert cfengine-ts-mode-tests--three-blocks)
      (cfengine-ts-mode)
      ;; From inside block one to inside block two.
      (let ((beg (progn (goto-char (point-min)) (search-forward "\"a\"")))
            (end (progn (search-forward "\"b\"") (point))))
        (cfengine-ts-mode-format-region beg end))
      (should (equal (buffer-string)
                     (concat "# header\n"
                             (cfengine-ts-mode-tests--block 1) "\n"
                             "\n# between\n"
                             (cfengine-ts-mode-tests--block 2) "\n"
                             "\n"
                             "bundle agent three\n{\nvars:\n\"c\"   string => \"3\";\n}\n"))))))

(ert-deftest cfengine-ts-mode-format-region-block-at-point ()
  (cfengine-ts-mode-tests--with-cli
    (with-temp-buffer
      (insert cfengine-ts-mode-tests--three-blocks)
      (cfengine-ts-mode)
      (goto-char (point-min))
      (search-forward "\"b\"   string")
      (call-interactively #'cfengine-ts-mode-format-region)
      ;; Point stays on the same word.
      (should (looking-back "string" (line-beginning-position)))
      (should (string-search (cfengine-ts-mode-tests--block 2) (buffer-string)))
      (should (string-search "\"a\"   string" (buffer-string)))
      (should (string-search "\"c\"   string" (buffer-string)))
      ;; Between blocks there is nothing to format.
      (goto-char (point-min))
      (search-forward "# between")
      (should-error (call-interactively #'cfengine-ts-mode-format-region)
                    :type 'user-error))))

(ert-deftest cfengine-ts-mode-format-region-all-or-nothing ()
  (cfengine-ts-mode-tests--with-cli
    (with-temp-buffer
      (let ((text (concat "bundle agent one\n{\nvars:\n\"a\"   string => \"1\";\n}\n"
                          "bundle agent two\n{\nvars:\n\"b\" string => {{ \"2\";\n}\n")))
        (insert text)
        (cfengine-ts-mode)
        (should-error (cfengine-ts-mode-format-region (point-min) (point-max))
                      :type 'user-error)
        (should (equal (buffer-string) text))))))

;;; Linting

(ert-deftest cfengine-ts-mode-lint-parses-output ()
  (with-temp-buffer
    (insert "bundle agent main\n{\n  vars:\n"
            "    \"x\" string => nosuchfn(\"a\"), ifvarclass => \"linux\";\n"
            "    \"y\" string => \"b\";\n}\n")
    (let ((source (current-buffer))
          (file "/tmp/cfengine-lint123.cf"))
      (with-temp-buffer
        (insert "    \"x\" string => nosuchfn(\"a\"), ifvarclass => \"linux\";\n"
                "                  ^------^\n"
                "Error: Call to unknown function 'nosuchfn' at " file ":4:19\n"
                "Hint: The body 'nosuchfn' is defined nowhere\n"
                "                                 ^--------^\n"
                "Deprecation: Use 'if' instead of 'ifvarclass' at " file ":4:34\n"
                "Error: Something in another file at /x/other.cf:1:1\n"
                "FAIL: " file " (2 errors)\n")
        (let ((diags (cfengine-ts-mode--lint-diagnostics source file)))
          (should (equal
                   (mapcar (lambda (d)
                             (list (flymake-diagnostic-type d)
                                   (with-current-buffer source
                                     (buffer-substring (flymake-diagnostic-beg d)
                                                       (flymake-diagnostic-end d)))
                                   (flymake-diagnostic-text d)))
                           diags)
                   '((:error "nosuchfn"
                             "Call to unknown function 'nosuchfn'. The body 'nosuchfn' is defined nowhere")
                     (:warning "ifvarclass" "Use 'if' instead of 'ifvarclass'")))))
        ;; A failure we can't place is still reported, on line 1.
        (erase-buffer)
        (insert "Something unexpected\nFAIL: " file " (1 error)\n")
        (let ((diags (cfengine-ts-mode--lint-diagnostics source file)))
          (should (= (length diags) 1))
          (should (eq (flymake-diagnostic-type (car diags)) :error))
          (should (= (flymake-diagnostic-beg (car diags)) 1)))))))

(defun cfengine-ts-mode-tests--lint (text file)
  "Lint TEXT as if visiting FILE; return (TYPE TEXT-AT-REGION) per problem."
  (with-temp-buffer
    (insert text)
    (cfengine-ts-mode)
    (setq buffer-file-name file)
    (let (result done)
      (cfengine-ts-mode-flymake (lambda (diags &rest _)
                                  (setq result diags done t)))
      (with-timeout (60 (error "cfengine lint timed out"))
        (while (not done) (accept-process-output nil 0.1)))
      (setq buffer-file-name nil)
      (mapcar (lambda (d)
                (list (flymake-diagnostic-type d)
                      (buffer-substring (flymake-diagnostic-beg d)
                                        (flymake-diagnostic-end d))))
              result))))

(defconst cfengine-ts-mode-tests--lint-policy
  (concat "bundle agent main\n{\n"
          "  files:\n    \"/tmp/x\"\n      perms => mog(\"0644\", \"root\", \"root\");\n"
          "  vars:\n    \"x\" string => nosuchfn(\"a\"), ifvarclass => \"linux\";\n}\n"))

(ert-deftest cfengine-ts-mode-lint-standalone ()
  (cfengine-ts-mode-tests--with-cli
    ;; Outside a policy tree, mog can't be resolved, so strict mode is
    ;; off: only the unknown built-in function is reported.
    (should (equal (cfengine-ts-mode-tests--lint
                    cfengine-ts-mode-tests--lint-policy
                    (expand-file-name "main.cf" temporary-file-directory))
                   '((:error "nosuchfn"))))))

(ert-deftest cfengine-ts-mode-lint-in-policy-tree ()
  (cfengine-ts-mode-tests--with-cli
    (let ((root (make-temp-file "cfengine-ts-mode-policy" t)))
      (unwind-protect
          (progn
            (make-directory (expand-file-name "lib" root))
            (make-directory (expand-file-name "services" root))
            (with-temp-file (expand-file-name "promises.cf" root)
              (insert "bundle agent other\n{\n}\n"))
            (with-temp-file (expand-file-name "lib/files.cf" root)
              (insert "body perms mog(mode, user, group)\n{\n"
                      "  mode => \"$(mode)\";\n}\n"))
            ;; In strict mode with the tree as context, mog resolves and
            ;; the deprecation is reported too.
            (should (equal (cfengine-ts-mode-tests--lint
                            cfengine-ts-mode-tests--lint-policy
                            (expand-file-name "services/main.cf" root))
                           '((:error "nosuchfn") (:warning "ifvarclass")))))
        (delete-directory root t)))))

(ert-deftest cfengine-ts-mode-lint-falls-back-when-context-breaks ()
  (cfengine-ts-mode-tests--with-cli
    (let ((root (make-temp-file "cfengine-ts-mode-policy" t)))
      (unwind-protect
          (progn
            (with-temp-file (expand-file-name "promises.cf" root)
              (insert "bundle agent other\n{\n}\n"))
            ;; A context file that doesn't parse stops lint before it
            ;; reaches the buffer.
            (with-temp-file (expand-file-name "broken.cf" root)
              (insert "bundle agent broken\n{\n  vars:\n    \"x\" string => \"a\"\n}\n"))
            (let ((diags (cfengine-ts-mode-tests--lint
                          cfengine-ts-mode-tests--lint-policy
                          (expand-file-name "main.cf" root))))
              (should (equal (mapcar #'car diags) '(:note :error)))
              (should (equal (cadr (nth 1 diags)) "nosuchfn"))))
        (delete-directory root t)))))

(ert-deftest cfengine-ts-mode-lint-reports-when-it-cannot-run ()
  (cfengine-ts-mode-tests--with-cli
    (let ((cfengine-ts-mode-lint-arguments '("--bogus")))
      (should (equal (mapcar #'car (cfengine-ts-mode-tests--lint
                                    cfengine-ts-mode-tests--lint-policy
                                    (expand-file-name "main.cf"
                                                      temporary-file-directory)))
                     '(:error))))))

(ert-deftest cfengine-ts-mode-fontifies-bundle-and-body-references ()
  (skip-unless (treesit-ready-p 'cfengine t))
  (with-temp-buffer
    (insert "body common control\n{\n  bundlesequence => { main, @(x) };\n}\n"
            "bundle agent main\n{\n  methods:\n    \"a\" usebundle => helper;\n"
            "  vars:\n    \"v\" slist => getvalues(input);\n}\n")
    (cfengine-ts-mode)
    (font-lock-ensure)
    (dolist (case '(("{ main" . font-lock-function-call-face)
                    ("@(x" . font-lock-variable-use-face)
                    ("=> helper" . font-lock-function-call-face)
                    ("getvalues" . font-lock-function-call-face)
                    ("(input" . font-lock-variable-use-face)))
      (goto-char (point-min))
      (search-forward (car case))
      (should (eq (get-text-property (1- (point)) 'face) (cdr case))))))

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
