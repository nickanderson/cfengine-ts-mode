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

(ert-deftest cfengine-ts-mode-indent-while-typing ()
  "Typing the fixture from scratch lays it out as `cfengine format' does.
Each line is typed without its indentation, character by character with
`electric-indent-mode', so blocks stay unclosed until their brace is
typed and the tree is incomplete throughout."
  (skip-unless (treesit-ready-p 'cfengine t))
  (let* ((want (with-temp-buffer
                 (insert-file-contents
                  (expand-file-name "indent.cf" cfengine-ts-mode-tests--dir))
                 (buffer-string)))
         (lines (split-string want "\n")))
    (with-temp-buffer
      (cfengine-ts-mode)
      (electric-indent-local-mode 1)
      (let ((first t))
        (dolist (line lines)
          (unless first
            (let ((last-command-event ?\n))
              (call-interactively #'newline)))
          (setq first nil)
          ;; In a multi-line string, leading whitespace is content.
          (dolist (char (string-to-list (if (nth 3 (syntax-ppss))
                                            line
                                          (string-trim-left line))))
            (let ((last-command-event char))
              (call-interactively #'self-insert-command)))))
      (should (equal (buffer-substring-no-properties (point-min) (point-max))
                     want)))))

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
    (should-not (policy-p "/x/promises.cf.in" "bundle agent main\n"))
    (should-not (policy-p "/x/test.cf.sub.in" "bundle agent main\n"))
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
                                   (cfengine-ts-mode--diagnostic-message d)))
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

(ert-deftest cfengine-ts-mode-flycheck ()
  "The Flycheck checker reports what the Flymake backend does."
  (cfengine-ts-mode-tests--with-cli
    (skip-unless (require 'flycheck nil t))
    (with-temp-buffer
      (insert cfengine-ts-mode-tests--lint-policy)
      (setq buffer-file-name (expand-file-name "main.cf" temporary-file-directory))
      (cfengine-ts-mode)
      (should (eq (flycheck-get-checker-for-buffer) 'cfengine-lint))
      (flycheck-mode 1)
      (flycheck-buffer)
      (with-timeout (60 (error "Flycheck timed out"))
        (while (flycheck-running-p) (accept-process-output nil 0.1)))
      (should (equal (mapcar (lambda (e)
                               (list (flycheck-error-level e)
                                     (flycheck-error-line e)
                                     (flycheck-error-column e)))
                             flycheck-current-errors)
                     '((error 7 19))))
      (set-buffer-modified-p nil)
      (setq buffer-file-name nil))))

(ert-deftest cfengine-ts-mode-lint-context-skips-lock-files ()
  (let ((root (make-temp-file "cfengine-ts-mode-policy" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "promises.cf" root)
            (insert "bundle agent other\n{\n}\n"))
          (with-temp-file (expand-file-name "lib.cf" root)
            (insert "body perms mog(m, o, g)\n{\n}\n"))
          ;; What Emacs leaves while main.cf has unsaved changes.
          (make-symbolic-link "user@host.1234:1" (expand-file-name ".#main.cf" root))
          (with-temp-buffer
            (setq buffer-file-name (expand-file-name "main.cf" root))
            (should (equal (sort (mapcar #'file-name-nondirectory
                                         (cfengine-ts-mode--lint-context))
                                 #'string<)
                           '("lib.cf" "promises.cf")))
            (setq buffer-file-name nil)))
      (delete-directory root t))))

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

;;; Completion and ElDoc from the cf-promises syntax

(defmacro cfengine-ts-mode-tests--with-syntax (&rest body)
  "Run BODY if `cf-promises' provides promise type syntax, else skip."
  (declare (indent 0))
  `(progn
     (skip-unless (cfengine-ts-mode--syntax 'promiseTypes))
     ,@body))

(defconst cfengine-ts-mode-tests--definitions
  (concat "body perms m(mode)\n{\n  mode => \"$(mode)\";\n}\n"
          "bundle edit_line my_lines\n{\n}\n"
          "bundle agent helper\n{\n}\n"))

(defun cfengine-ts-mode-tests--complete (text)
  "Return (PREFIX CANDIDATES CAPF) at the | in TEXT, a policy snippet."
  (with-temp-buffer
    (insert cfengine-ts-mode-tests--definitions text)
    (cfengine-ts-mode)
    (search-backward "|")
    (delete-char 1)
    ;; As `completion-at-point': a non-exclusive table with no match for
    ;; the prefix gives way to the next function.
    (let ((capf (run-hook-wrapped
                 'completion-at-point-functions
                 (lambda (f)
                   (when-let* ((capf (and (functionp f) (funcall f))))
                     (and (or (not (eq (plist-get (nthcdr 3 capf) :exclusive) 'no))
                              (all-completions
                               (buffer-substring-no-properties (nth 0 capf) (nth 1 capf))
                               (nth 2 capf)))
                          capf))))))
      (when capf
        (let ((prefix (buffer-substring-no-properties (nth 0 capf) (nth 1 capf))))
          (list prefix (all-completions prefix (nth 2 capf)) capf))))))

(ert-deftest cfengine-ts-mode-completes-promise-types ()
  (cfengine-ts-mode-tests--with-syntax
    (should (equal (nth 1 (cfengine-ts-mode-tests--complete
                           "bundle agent main\n{\n  vars:\n    \"x\" string => \"a\";\n  fi|\n}\n"))
                   '("files")))
    ;; Only the promise types of the bundle's type.
    (should (equal (nth 1 (cfengine-ts-mode-tests--complete
                           "bundle edit_line e\n{\n  ins|\n}\n"))
                   '("insert_lines")))
    (should-not (member "insert_lines"
                        (nth 1 (cfengine-ts-mode-tests--complete
                                "bundle agent main\n{\n  ins|\n}\n"))))))

(defconst cfengine-ts-mode-tests--custom
  "promise agent git
{
  path => \"/var/cfengine/modules/promises/git.py\";
  interpreter => \"/usr/bin/python3\";
}
bundle agent other
{
  git:
    \"/srv/a\"
      repository => \"https://example.com/a.git\",
      version => \"main\";
}
"
  "A custom promise type and a use of it.")

(ert-deftest cfengine-ts-mode-completes-custom-promise-types ()
  (cfengine-ts-mode-tests--with-syntax
    (let ((complete (lambda (text)
                      (cfengine-ts-mode-tests--complete
                       (concat cfengine-ts-mode-tests--custom text)))))
      ;; The type itself, in agent bundles only.
      (let ((result (funcall complete "bundle agent main\n{\n  gi|\n}\n")))
        (should (equal (nth 1 result) '("git")))
        (should (equal (funcall (plist-get (nthcdr 3 (nth 2 result))
                                           :annotation-function)
                                "git")
                       " custom promise type")))
      (should-not (member "git" (nth 1 (funcall complete
                                                "bundle edit_line e\n{\n  gi|\n}\n"))))
      ;; Its attributes: those of every promise type, and those used with it.
      (let ((candidates
             (nth 1 (funcall complete
                             "bundle agent main\n{\n  git:\n    \"/srv/b\"\n      |\n}\n"))))
        (dolist (name '("if" "unless" "meta" "classes" "repository" "version"))
          (should (member name candidates)))
        (should-not (member "create" candidates)))
      ;; A promise block's attributes.
      (should (equal (nth 1 (cfengine-ts-mode-tests--complete
                             "promise agent p\n{\n  inter|\n}\n"))
                     '("interpreter"))))))

(ert-deftest cfengine-ts-mode-custom-promise-type-docs-and-xref ()
  (cfengine-ts-mode-tests--with-syntax
    (with-temp-buffer
      (insert cfengine-ts-mode-tests--custom)
      (cfengine-ts-mode)
      (let ((cfengine-ts-mode-docs-version "lts"))
        (dolist (case '(("interpreter" "promise-types/custom/")
                        ("git:" "promise-types/custom/")
                        ("repository" "promise-types/custom/")
                        ("main\"" "promise-types/custom/")))
          (goto-char (point-min))
          (search-forward (car case))
          (goto-char (1+ (match-beginning 0)))
          (should (equal (cfengine-ts-mode-docs-url)
                         (concat "https://docs.cfengine.com/docs/lts/reference/"
                                 (cadr case))))))
      ;; ElDoc says nothing about the type's own attributes.
      (goto-char (point-min))
      (search-forward "repository")
      (should-not (cfengine-ts-mode--eldoc-attribute))
      (should (equal (mapcar #'xref-item-summary
                             (xref-backend-definitions 'cfengine-ts "git"))
                     '("promise agent git"))))))

(defconst cfengine-ts-mode-tests--variables
  "bundle common g
{
  vars:
      \"list\" slist => {
        \"not_a_var\",
        \"nor_this\"
      };
      \"long\" string =>
        \"not_a_var_either\";
      \"array[key]\" string => \"v\";
  classes:
    linux::
      \"g_ready\" expression => \"any\"; # \"commented\"
}
"
  "Variables and classes, with lines that only look like promisers.")

(ert-deftest cfengine-ts-mode-scans-variables-and-classes ()
  (with-temp-buffer
    (insert cfengine-ts-mode-tests--variables
            "bundle agent main(x, y)\n{\n  vars:\n    \"z\" string => \"$(x)\";\n}\n")
    (cfengine-ts-mode)
    (should (equal (mapcar (lambda (d) (seq-take d 3))
                           (cfengine-ts-mode--scan-definitions))
                   '(("bundle" "common" "g")
                     ("vars" "g" "list") ("vars" "g" "long") ("vars" "g" "array")
                     ("classes" "g" "g_ready")
                     ("bundle" "agent" "main")
                     ("parameter" "main" "x") ("parameter" "main" "y")
                     ("vars" "main" "z")))))
  ;; Scanning keeps its match data across `syntax-ppss', which can
  ;; clobber it in a parsed buffer.
  (cfengine-ts-mode-tests--with-fixture "indent.cf"
    (should (cfengine-ts-mode--scan-definitions))))

(ert-deftest cfengine-ts-mode-completes-variables ()
  (let ((complete (lambda (text)
                    (cfengine-ts-mode-tests--complete
                     (concat cfengine-ts-mode-tests--variables text))))
        (main "bundle agent main(x)\n{\n  vars:\n    \"z\" string => \"a\";\n    \"w\" string => \"%s\";\n}\n"))
    ;; The block's own variables and parameters, unqualified.
    (let ((result (funcall complete (format main "$(|)"))))
      (dolist (name '("x" "z" "w" "g.list" "g.long" "g.array" "this.promiser"))
        (should (member name (nth 1 result))))
      (should-not (member "list" (nth 1 result)))
      (should-not (member "g.not_a_var" (nth 1 result))))
    (should (equal (nth 1 (funcall complete (format main "${g.lo|}")))
                   '("g.long")))
    ;; Completing closes the reference.
    (with-temp-buffer
      (insert cfengine-ts-mode-tests--variables (format main "$(g.lo|"))
      (cfengine-ts-mode)
      (search-backward "|")
      (delete-char 1)
      (completion-at-point)
      (should (looking-back (regexp-quote "$(g.long)") (line-beginning-position))))
    ;; The built-ins, from cf-promises.
    (when (car (cfengine-ts-mode--builtins))
      (should (member "sys.arch" (nth 1 (funcall complete (format main "$(sys.ar|)"))))))))

(ert-deftest cfengine-ts-mode-completes-classes ()
  (let ((complete (lambda (text)
                    (cfengine-ts-mode-tests--complete
                     (concat cfengine-ts-mode-tests--variables text)))))
    ;; In a class guard, and in a class expression.
    (should (member "g_ready" (nth 1 (funcall complete
                                              "bundle agent main\n{\n  vars:\n    g_re|\n}\n"))))
    (should (member "g_ready" (nth 1 (funcall complete
                                              "bundle agent main\n{\n  vars:\n    linux.!g_re|\n}\n"))))
    (should (member "g_ready" (nth 1 (funcall complete
                                              "bundle agent main\n{\n  vars:\n    \"v\" string => \"a\",\n      if => \"linux.g_re|\";\n}\n"))))
    ;; Not in other strings, nor in a promise's attributes.
    (should-not (member "g_ready" (nth 1 (funcall complete
                                                  "bundle agent main\n{\n  vars:\n    \"v\" string => \"g_re|\";\n}\n"))))
    (should-not (member "g_ready" (nth 1 (funcall complete
                                                  "bundle agent main\n{\n  vars:\n    \"v\"\n      g_re|\n}\n"))))
    (when (cdr (cfengine-ts-mode--builtins))
      (should (member "any" (nth 1 (funcall complete
                                            "bundle agent main\n{\n  vars:\n    an|\n}\n")))))))

(ert-deftest cfengine-ts-mode-xref-variables-and-classes ()
  (with-temp-buffer
    (insert cfengine-ts-mode-tests--variables
            "bundle agent main(x)\n{\n  vars:\n    \"z\" string => \"$(x)\";\n"
            "    \"long\" string => \"$(z) ${g.long} $(long) $(default:g.list)\";\n"
            "  reports:\n    g_ready::\n      \"ok\";\n}\n")
    (cfengine-ts-mode)
    (cl-flet ((definitions-at (text)
                (goto-char (point-min))
                (search-forward text)
                (mapcar #'xref-item-summary
                        (xref-backend-definitions
                         'cfengine-ts (xref-backend-identifier-at-point 'cfengine-ts)))))
      (should (equal (definitions-at "$(x") '("parameter main.x")))
      (should (equal (definitions-at "$(z") '("vars main.z")))
      (should (equal (definitions-at "${g.lo") '("vars g.long")))
      ;; Unqualified: the block's own first.
      (should (equal (definitions-at "$(lo") '("vars main.long")))
      (should (equal (definitions-at "default:g.li") '("vars g.list")))
      (should (equal (definitions-at "g_rea") '("classes g.g_ready")))
      (should (equal (definitions-at "bundle agent ma") '("bundle agent main"))))
    (should (member "g.long" (xref-backend-identifier-completion-table 'cfengine-ts)))
    ;; References to a variable, qualified or not.
    (should (= (length (xref-backend-references 'cfengine-ts "g.long")) 4))))

(ert-deftest cfengine-ts-mode-completes-attributes ()
  (cfengine-ts-mode-tests--with-syntax
    (should (equal (nth 1 (cfengine-ts-mode-tests--complete
                           "bundle agent main\n{\n  files:\n    \"/tmp/x\"\n      cre|\n}\n"))
                   '("create")))
    (should (equal (nth 1 (cfengine-ts-mode-tests--complete
                           "bundle agent main\n{\n  files:\n    \"/tmp/x\" cre|\n}\n"))
                   '("create")))
    ;; In a body, the body type's attributes.
    (should (equal (nth 1 (cfengine-ts-mode-tests--complete "body perms p\n{\n  mo|\n}\n"))
                   '("mode")))))

(ert-deftest cfengine-ts-mode-completes-values ()
  (cfengine-ts-mode-tests--with-syntax
    (dolist (case '(;; Options, inside the quotes.
                    ("files:\n    \"/tmp/x\"\n      create => \"t|" "t" ("true"))
                    ;; Bodies of the attribute's type, with or without arguments.
                    ("files:\n    \"/tmp/x\"\n      perms => |" "" ("m"))
                    ("files:\n    \"/tmp/x\"\n      perms => m|(\"0644\");" "m" ("m"))
                    ;; Bundles of the right type.
                    ("files:\n    \"/tmp/x\"\n      edit_line => my|" "my" ("my_lines"))
                    ("methods:\n    \"a\" usebundle => \"hel|\";" "hel" ("helper"))))
      (let ((result (cfengine-ts-mode-tests--complete
                     (concat "bundle agent main\n{\n  " (car case) "\n}\n"))))
        (should (equal (list (nth 0 result) (nth 1 result)) (cdr case)))))))

(ert-deftest cfengine-ts-mode-completion-inserts-punctuation ()
  (cfengine-ts-mode-tests--with-syntax
    (with-temp-buffer
      (insert "bundle agent main\n{\n  fi\n}\n")
      (cfengine-ts-mode)
      (goto-char (point-min))
      (search-forward "  fi")
      (let ((capf (cfengine-ts-mode--syntax-completion-at-point)))
        (insert "les")
        (funcall (plist-get (nthcdr 3 capf) :exit-function) "files" 'finished))
      (should (equal (buffer-substring (line-beginning-position) (line-end-position))
                     "  files:"))
      (insert "\n\"/tmp/x\"\ncr")
      (let ((capf (cfengine-ts-mode--syntax-completion-at-point)))
        (insert "eate")
        (funcall (plist-get (nthcdr 3 capf) :exit-function) "create" 'finished))
      (should (looking-back "create => " (line-beginning-position))))))

(ert-deftest cfengine-ts-mode-eldoc-attributes ()
  (cfengine-ts-mode-tests--with-syntax
    (with-temp-buffer
      (insert "bundle agent main\n{\n  files:\n    \"/tmp/x\"\n"
              "      create => \"true\",\n      perms => m(\"0644\");\n}\n")
      (cfengine-ts-mode)
      (goto-char (point-min))
      ;; On the name, and in the value.
      (search-forward "crea")
      (should (equal (substring-no-properties (cfengine-ts-mode--eldoc-attribute))
                     "create: option (true,false,yes,no,on,off)"))
      (search-forward "tr")
      (should (string-prefix-p "create:" (cfengine-ts-mode--eldoc-attribute)))
      (search-forward "m(")
      (should (equal (substring-no-properties (cfengine-ts-mode--eldoc-attribute))
                     "perms: body perms")))))

(ert-deftest cfengine-ts-mode-xref ()
  (let ((root (make-temp-file "cfengine-ts-mode-policy" t))
        (lib nil))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "promises.cf" root)
            (insert "body common control\n{\n"
                    "  bundlesequence => { \"main\", helper };\n}\n"))
          (setq lib (expand-file-name "lib.cf" root))
          (with-temp-file lib
            (insert "# mog sets mode, owner and group\n"
                    "body perms mog(m, o, g)\n{\n  mode => \"$(m)\";\n}\n"))
          (with-temp-buffer
            (insert "bundle agent main\n{\n  files:\n    \"/tmp/x\"\n"
                    "      perms => mog(\"644\", \"root\", \"root\");\n"
                    "  methods:\n    \"h\" usebundle => \"helper\";\n}\n"
                    "bundle agent helper\n{\n}\n")
            (cfengine-ts-mode)
            (setq buffer-file-name (expand-file-name "main.cf" root))
            (unwind-protect
                (cl-flet ((where (items)
                            (mapcar (lambda (x)
                                      (let ((loc (xref-item-location x)))
                                        (list (file-name-nondirectory
                                               (or (xref-location-group loc) ""))
                                              ;; Buffer locations have a
                                              ;; position, not a line.
                                              (or (xref-location-line loc)
                                                  (let ((m (xref-location-marker loc)))
                                                    (with-current-buffer (marker-buffer m)
                                                      (line-number-at-pos m)))))))
                                    items)))
                  (goto-char (point-min))
                  (search-forward "mo")
                  (should (equal (xref-backend-identifier-at-point 'cfengine-ts) "mog"))
                  ;; Defined in another file of the tree.
                  (should (equal (where (xref-backend-definitions 'cfengine-ts "mog"))
                                 '(("lib.cf" 2))))
                  ;; Defined in this buffer, and named in a string.
                  (search-forward "\"hel")
                  (should (equal (xref-backend-identifier-at-point 'cfengine-ts) "helper"))
                  (should (equal (mapcar #'xref-item-summary
                                         (xref-backend-definitions 'cfengine-ts "helper"))
                                 '("bundle agent helper")))
                  ;; References: here and in the tree,
                  ;; comments not.
                  (should (equal (sort (where (xref-backend-references 'cfengine-ts "mog"))
                                       (lambda (a b) (string< (format "%S" a) (format "%S" b))))
                                 '(("lib.cf" 2) ("main.cf" 5))))
                  (should (member '("promises.cf" 3)
                                  (where (xref-backend-references 'cfengine-ts "helper"))))
                  ;; An unsaved buffer visiting a tree file is read instead
                  ;; of the file.
                  (let ((buffer (find-file-noselect lib)))
                    (unwind-protect
                        (with-current-buffer buffer
                          (goto-char (point-min))
                          (insert "\n\n")
                          (should (buffer-modified-p))
                          (with-temp-buffer
                            (insert "bundle agent x\n{\n}\n")
                            (cfengine-ts-mode)
                            (setq buffer-file-name (expand-file-name "x.cf" root))
                            (should (equal (where (xref-backend-definitions
                                                   'cfengine-ts "mog"))
                                           '(("lib.cf" 4))))
                            (setq buffer-file-name nil)))
                      (with-current-buffer buffer (set-buffer-modified-p nil))
                      (kill-buffer buffer))))
              (set-buffer-modified-p nil)
              (setq buffer-file-name nil))))
      (delete-directory root t))))

(ert-deftest cfengine-ts-mode-docs-urls ()
  "Each URL was checked against docs.cfengine.com, anchor included."
  (cfengine-ts-mode-tests--with-syntax
    (with-temp-buffer
      (insert "body agent control\n{\n  ifelapsed => \"1\";\n}\n"
              "body action a\n{\n  ifelapsed => \"1\";\n}\n"
              "body perms p\n{\n  mode => \"0644\";\n}\n"
              "bundle agent main\n{\n  files:\n    \"/tmp/x\"\n"
              "      create => \"true\",\n      perms => m(\"0644\"),\n"
              "      if => \"linux\";\n"
              "  vars:\n    \"j\" string => join(\",\", \"l\");\n}\n")
      (cfengine-ts-mode)
      (goto-char (point-min))
      (let ((cfengine-ts-mode-docs-version "lts"))
        (dolist (case '(;; Control body: the component's page.
                        ("ifelapsed" "components/cf-agent/#ifelapsed")
                        ;; A body used by every promise type.
                        ("ifelapsed" "promise-types/#ifelapsed")
                        ;; A body's page is its promise type's.
                        ("mode" "promise-types/files/#mode")
                        ("files" "promise-types/files/")
                        ("create" "promise-types/files/#create")
                        ;; In a value: its attribute.
                        ("tru" "promise-types/files/#create")
                        ("perms" "promise-types/files/#perms")
                        ("if =>" "promise-types/#if")
                        ("join" "functions/join/")))
          (search-forward (car case))
          (goto-char (1+ (match-beginning 0)))
          (should (equal (cfengine-ts-mode-docs-url)
                         (concat "https://docs.cfengine.com/docs/lts/reference/"
                                 (cadr case)))))
        (goto-char (point-min))
        (should (equal (cfengine-ts-mode-docs-url)
                       "https://docs.cfengine.com/docs/lts/reference/"))))))

;;; Navigation and outline

(ert-deftest cfengine-ts-mode-sentences-are-promises ()
  (skip-unless (treesit-ready-p 'cfengine t))
  (cfengine-ts-mode-tests--with-fixture "indent.cf"
    (goto-char (point-min))
    (search-forward "  vars:")
    (forward-line 1)
    (back-to-indentation)
    (forward-sentence)
    (should (looking-back "{ \"a\", \"b\", \"c\" };" (line-beginning-position)))
    (forward-sentence)
    (should (looking-back "join(\",\", \"list\");" (line-beginning-position)))
    ;; In a body, attribute by attribute, ending after the ";".
    (goto-char (point-min))
    (search-forward "body agent control")
    (forward-line 2)
    (forward-sentence)
    (should (looking-back "ifelapsed => \"1\";" (line-beginning-position)))
    (forward-sentence)
    (should (looking-back "maxconnections => \"10\";" (line-beginning-position)))))

(ert-deftest cfengine-ts-mode-outline-blocks-and-sections ()
  (skip-unless (treesit-ready-p 'cfengine t))
  (require 'outline)
  (cfengine-ts-mode-tests--with-fixture "indent.cf"
    (outline-minor-mode 1)
    (cl-flet ((visible-lines ()
                (let (lines)
                  (save-excursion
                    (goto-char (point-min))
                    (while (not (eobp))
                      (unless (invisible-p (point))
                        (push (buffer-substring (line-beginning-position)
                                                (line-end-position))
                              lines))
                      (forward-line 1)))
                  (nreverse lines))))
      (outline-hide-sublevels 1)
      (should (member "bundle agent main(param)" (visible-lines)))
      (should-not (member "  vars:" (visible-lines)))
      ;; One level down shows the sections.
      (goto-char (point-min))
      (search-forward "bundle agent main")
      (outline-show-children)
      (should (member "  vars:" (visible-lines)))
      (should (member "  files:" (visible-lines)))
      (should-not (member "      create => \"true\"," (visible-lines))))))

(ert-deftest cfengine-ts-mode-key-bindings ()
  (with-temp-buffer
    (cfengine-ts-mode)
    (should (eq (key-binding (kbd "C-c C-f")) #'cfengine-ts-mode-format-buffer))
    (should (eq (key-binding (kbd "C-c C-r")) #'cfengine-ts-mode-format-region))
    (should (eq (key-binding (kbd "C-c C-j")) #'cfengine3-reformat-json-string))
    (should (eq (key-binding (kbd "C-c C-d")) #'cfengine-ts-mode-browse-docs))))

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
