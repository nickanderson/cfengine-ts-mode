;;; cfengine-ts-mode.el --- Tree-sitter major mode for CFEngine 3 policy -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Nick Anderson

;; Author: Nick Anderson <nick@cmdln.org>
;; Maintainer: Nick Anderson <nick@cmdln.org>
;; URL: https://github.com/nickanderson/cfengine-ts-mode
;; Version: 0.1.0
;; Keywords: languages cfengine
;; Package-Requires: ((emacs "30.1"))
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;; Permission is hereby granted, free of charge, to any person obtaining
;; a copy of this software and associated documentation files (the
;; "Software"), to deal in the Software without restriction, including
;; without limitation the rights to use, copy, modify, merge, publish,
;; distribute, sublicense, and/or sell copies of the Software, and to
;; permit persons to whom the Software is furnished to do so, subject to
;; the following conditions:
;;
;; The above copyright notice and this permission notice shall be
;; included in all copies or substantial portions of the Software.
;;
;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
;; EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
;; MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
;; NONINFRINGEMENT.  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
;; LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
;; OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
;; WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

;;; Commentary:

;; Major mode for CFEngine 3 policy using the tree-sitter grammar that
;; `cfengine format' and `cfengine lint' are built on:
;; https://github.com/olehermanse/tree-sitter-cfengine
;;
;; Highlighting follows the Zed extension's highlights.scm
;; (https://github.com/olehermanse/zed-cfengine), mapped onto standard
;; Emacs faces.  Indentation follows `cfengine format'.
;;
;; Install the grammar once with M-x cfengine-ts-mode-install-grammar.
;; When it is available, `cfengine-mode' and `cfengine3-mode' are
;; remapped to this mode, which also covers Org src blocks in "cfengine3".
;;
;; `.cf' is shared with Postfix and sendmail, so files are recognized by
;; content: a `.cf', `.cf.sub', `.cf.in' or `.cf.sub.in' file with a
;; bundle, body or promise block opens in `cfengine3-mode', or in this
;; mode once the grammar is installed.
;;
;; Function completion and ElDoc signatures come from `cfengine.el'.
;; They use the syntax of the installed `cf-promises' (see
;; `cfengine-cf-promises'), or built-in data when it isn't found.

;;; Code:

(require 'treesit)
(require 'cfengine)
(require 'flymake)

(defgroup cfengine-ts nil
  "Tree-sitter support for CFEngine 3 policy."
  :group 'cfengine)

(defcustom cfengine-ts-mode-indent-offset 2
  "Number of spaces for each indentation level in `cfengine-ts-mode'."
  :type 'integer
  :safe #'integerp)

(defcustom cfengine-ts-mode-cfengine-program "cfengine"
  "The CFEngine CLI, used for `cfengine format' and `cfengine lint'."
  :type 'string
  :risky t)

(defcustom cfengine-ts-mode-format-on-save nil
  "Non-nil means format the buffer with `cfengine format' before saving."
  :type 'boolean
  :safe #'booleanp)

(defcustom cfengine-ts-mode-lint-arguments nil
  "Extra arguments for `cfengine lint'."
  :type '(repeat string)
  :risky t)

(add-to-list 'treesit-language-source-alist
             '(cfengine "https://github.com/olehermanse/tree-sitter-cfengine"))

;;; Activation

;; Keep in sync with the autoloaded form at the end of this file.
(defun cfengine-ts-mode--remap ()
  "Remap the regexp-based CFEngine modes to `cfengine-ts-mode'."
  (add-to-list 'major-mode-remap-defaults '(cfengine-mode . cfengine-ts-mode))
  (add-to-list 'major-mode-remap-defaults '(cfengine3-mode . cfengine-ts-mode)))

(defun cfengine-ts-mode-install-grammar ()
  "Build and install the CFEngine tree-sitter grammar."
  (interactive)
  (treesit-install-language-grammar 'cfengine)
  (when (treesit-language-available-p 'cfengine)
    (cfengine-ts-mode--remap)))

;; `magic-mode-alist' calls this for every file visited, so the whole
;; definition goes into the autoloads (via `progn') rather than a stub
;; that would load this package on the first visit.
;;;###autoload
(progn
  (defun cfengine-ts-mode-policy-file-p ()
    "Return non-nil if the current buffer looks like CFEngine policy.
The file name must end in .cf, .cf.sub, .cf.in or .cf.sub.in (the .in
forms are templates such as masterfiles' promises.cf.in), and the text
must contain a bundle, body or promise block header: the keyword, a
type and a name, then optionally a parameter list, an opening brace and
a comment, and nothing else on the line.  Keywords are case-sensitive,
as in CFEngine.  Intended for `magic-mode-alist'."
    (and buffer-file-name
         (string-match-p "\\.cf\\(?:\\.sub\\)?\\(?:\\.in\\)?\\'" buffer-file-name)
         ;; String regexp, not `rx': this runs from the autoloads.
         ;; The parameter list may continue on the next line.
         (let ((case-fold-search nil))
           (re-search-forward
            (concat "^[ \t]*\\(?:bundle\\|body\\|promise\\)"
                    "[ \t]+[[:alnum:]_]+[ \t]+[[:alnum:]_]+"
                    "[ \t]*\\(?:([^)\n]*)?\\)?"
                    "[ \t]*{?[ \t]*\\(?:#.*\\)?\r?$")
            nil t)))))

;;;###autoload
(add-to-list 'magic-mode-alist '(cfengine-ts-mode-policy-file-p . cfengine3-mode))

;;; Completion

(defun cfengine-ts-mode--completion-at-point ()
  "Complete CFEngine function names via `cfengine3-completion-function'.
Non-exclusive, and nil when `cf-promises' provides no syntax, so other
completion functions still get a turn."
  (when-let* ((capf (cfengine3-completion-function))
              ((nth 2 capf)))
    (append capf '(:exclusive no))))

;;; Font lock

(defun cfengine-ts-mode--fontify-string (node override start end &rest _)
  "Fontify string NODE, then $(var) and @(var) references inside it.
OVERRIDE, START and END are as in `treesit-font-lock-rules'."
  (let ((beg (treesit-node-start node))
        (fin (treesit-node-end node)))
    (treesit-fontify-with-override beg fin 'font-lock-string-face override start end)
    (save-excursion
      (goto-char beg)
      (while (re-search-forward "[$@][({][^\"(){}]*[)}]" fin t)
        (treesit-fontify-with-override (match-beginning 0) (match-end 0)
                                       'font-lock-variable-use-face
                                       'prepend start end)))))

(defvar cfengine-ts-mode--font-lock-settings
  (treesit-font-lock-rules
   :language 'cfengine
   :feature 'comment
   '((comment) @font-lock-comment-face)

   :language 'cfengine
   :feature 'preprocessor
   '((macro) @font-lock-preprocessor-face)

   :language 'cfengine
   :feature 'keyword
   '([(bundle_block_keyword) (body_block_keyword) (promise_block_keyword)]
     @font-lock-keyword-face
     [(bundle_block_type) (body_block_type) (promise_block_type)]
     @font-lock-type-face)

   :language 'cfengine
   :feature 'definition
   '([(bundle_block_name) (body_block_name) (promise_block_name)]
     @font-lock-function-name-face
     (parameter) @font-lock-variable-name-face)

   :language 'cfengine
   :feature 'guard
   '((promise_guard) @font-lock-builtin-face
     (class_guard) @font-lock-constant-face)

   :language 'cfengine
   :feature 'string
   '((promiser) @cfengine-ts-mode--fontify-string
     (quoted_string) @cfengine-ts-mode--fontify-string)

   :language 'cfengine
   :feature 'property
   '((attribute_name) @font-lock-property-name-face)

   :language 'cfengine
   :feature 'function
   '((calling_identifier) @font-lock-function-call-face)

   :language 'cfengine
   :feature 'variable
   '([(dollar_expression) (at_expression)] @font-lock-variable-use-face
     (qualified_identifier) @font-lock-variable-use-face)

   :language 'cfengine
   :feature 'operator
   '(["=>" "->"] @font-lock-operator-face)

   :language 'cfengine
   :feature 'delimiter
   '([";" ","] @font-lock-delimiter-face)

   :language 'cfengine
   :feature 'bracket
   '(["(" ")" "{" "}"] @font-lock-bracket-face)

   :language 'cfengine
   :feature 'error
   :override t
   '((ERROR) @font-lock-warning-face))
  "Tree-sitter font-lock settings for `cfengine-ts-mode'.")

;;; Indentation (matches `cfengine format')

(defun cfengine-ts-mode--inside-string-p (_node _parent bol)
  "Non-nil when BOL is a continuation line of a multi-line string."
  (let ((n (treesit-node-at bol)))
    (and (member (treesit-node-type n) '("quoted_string" "promiser"))
         (< (treesit-node-start n) bol))))

(defun cfengine-ts-mode--stakeholder-list-p (_node parent _bol)
  "Non-nil when PARENT is the { } list of a promise's stakeholders (->)."
  (and (equal (treesit-node-type parent) "list")
       (equal (treesit-node-type (treesit-node-parent parent)) "stakeholder")))

(defun cfengine-ts-mode--promise-start (_node parent _bol)
  "Anchor at the start of the promise enclosing PARENT."
  (treesit-node-start
   (treesit-parent-until parent (lambda (n) (equal (treesit-node-type n) "promise")) t)))

(defun cfengine-ts-mode--previous-promise-start (node _parent _bol)
  "Anchor at the promise before NODE, skipping @if/@else macros.
The grammar parses attributes after @else as a separate half_promise."
  (let ((n (treesit-node-prev-sibling node)))
    (while (and n (not (equal (treesit-node-type n) "promise")))
      (setq n (treesit-node-prev-sibling n)))
    (if n (treesit-node-start n) (treesit-node-start node))))

(defun cfengine-ts-mode--bol (_node _parent bol)
  "Anchor at BOL itself, leaving the line's indentation unchanged."
  bol)

;; Comments directly in a block, section, class guard, promise or
;; attribute follow `_comment_indent' in cfengine-cli's format.py.  Each
;; node of these types adds one level for its children.
(defconst cfengine-ts-mode--indented-types
  '("bundle_section" "class_guarded_promises" "class_guarded_body_attributes"
    "class_guarded_promise_block_attributes" "promise" "half_promise"
    "attribute")
  "Node types that indent their children one level.")

(defconst cfengine-ts-mode--block-body-types
  '("bundle_block_body" "promise_block_body" "body_block_body")
  "Node types holding the contents of a block.")

(defun cfengine-ts-mode--indented-p (node)
  "Non-nil if NODE indents its children one level."
  (and node (member (treesit-node-type node) cfengine-ts-mode--indented-types)))

(defun cfengine-ts-mode--level-column (node)
  "Return the column for children of NODE: one level per indenting node."
  (let ((levels 0))
    (while node
      (when (cfengine-ts-mode--indented-p node)
        (setq levels (1+ levels)))
      (setq node (treesit-node-parent node)))
    (* levels cfengine-ts-mode-indent-offset)))

(defun cfengine-ts-mode--content-sibling (node next)
  "Return the nearest named sibling of NODE that isn't a comment or macro.
Search forward when NEXT is non-nil, otherwise backward."
  (let ((n node))
    (while (and (setq n (if next (treesit-node-next-sibling n t)
                          (treesit-node-prev-sibling n t)))
                (member (treesit-node-type n) '("comment" "macro"))))
    n))

(defun cfengine-ts-mode--trailing-comment-column (prev column)
  "Return the column of the deepest content at the end of PREV.
COLUMN is the column for PREV's siblings."
  (while (cfengine-ts-mode--indented-p prev)
    (setq column (+ column cfengine-ts-mode-indent-offset))
    (setq prev (seq-find #'cfengine-ts-mode--indented-p
                         (reverse (treesit-node-children prev)))))
  column)

(defun cfengine-ts-mode--comment-in-body-p (node parent _bol)
  "Non-nil when NODE is a comment whose PARENT is a block or indenting node."
  (and (equal (treesit-node-type node) "comment")
       (or (cfengine-ts-mode--indented-p parent)
           (member (treesit-node-type parent)
                   cfengine-ts-mode--block-body-types))))

(defun cfengine-ts-mode--comment-offset (node parent _bol)
  "Return the column for comment NODE in PARENT, as `cfengine format' does.
A comment aligns with the next content sibling.  With none, it aligns
with the deepest content at the end of the previous one, so a trailing
comment stays with the block above it."
  (let* ((column (cfengine-ts-mode--level-column parent))
         (deeper (+ column cfengine-ts-mode-indent-offset))
         (nearest (cfengine-ts-mode--content-sibling node t)))
    (catch 'done
      (unless nearest
        (when (member (treesit-node-type parent) '("promise" "half_promise"))
          (throw 'done deeper))
        (let ((prev (cfengine-ts-mode--content-sibling node nil)))
          (when (cfengine-ts-mode--indented-p prev)
            (throw 'done
                   (cfengine-ts-mode--trailing-comment-column prev column)))
          (setq nearest prev)))
      (cond ((cfengine-ts-mode--indented-p nearest) deeper)
            ((and (null nearest)
                  (member (treesit-node-type parent)
                          cfengine-ts-mode--block-body-types))
             deeper)
            (t column)))))

(defvar cfengine-ts-mode--indent-rules
  ;; Node-type matchers are regexps, so anchor them: "promise" would
  ;; otherwise also match "class_guarded_promises".
  `((cfengine
     (cfengine-ts-mode--inside-string-p cfengine-ts-mode--bol 0)
     ((node-is ,(rx bos "macro" eos)) column-0 0)
     ((parent-is ,(rx bos "source_file" eos)) column-0 0)
     (cfengine-ts-mode--comment-in-body-p
      column-0 cfengine-ts-mode--comment-offset)
     ;; `cfengine format' quirk: stakeholder list items at promiser + 4,
     ;; its closing brace at promiser + 2.
     ((and cfengine-ts-mode--stakeholder-list-p (node-is ,(rx bos "}" eos)))
      cfengine-ts-mode--promise-start cfengine-ts-mode-indent-offset)
     (cfengine-ts-mode--stakeholder-list-p
      cfengine-ts-mode--promise-start ,(* 2 cfengine-ts-mode-indent-offset))
     ((node-is ,(rx bos "half_promise" eos))
      cfengine-ts-mode--previous-promise-start cfengine-ts-mode-indent-offset)
     ((node-is ,(rx bos (or "{" "}" ")") eos)) parent-bol 0)
     ((parent-is ,(rx bos (or "bundle_block_body" "body_block_body"
                              "promise_block_body")
                      eos))
      column-0 cfengine-ts-mode-indent-offset)
     ((parent-is ,(rx bos (or "bundle_section" "class_guarded_promises"
                              "class_guarded_body_attributes"
                              "class_guarded_promise_block_attributes"
                              "promise" "attribute" "list" "call")
                      eos))
      parent-bol cfengine-ts-mode-indent-offset)
     (no-node parent-bol cfengine-ts-mode-indent-offset)
     (catch-all parent-bol 0)))
  "Tree-sitter indentation rules for `cfengine-ts-mode'.")

;;; Navigation

(defun cfengine-ts-mode--defun-name (node)
  "Return the name of the bundle, body or promise block NODE."
  (when-let* ((name (treesit-search-subtree
                     node (rx (or "bundle_block_name" "body_block_name"
                                  "promise_block_name"))
                     nil nil 1)))
    (treesit-node-text name t)))

;;; Formatting

(defun cfengine-ts-mode-format-buffer ()
  "Format the buffer with `cfengine format'.
Only the changed regions are replaced, so point and marks are kept.
If the policy can't be parsed, the buffer is left alone."
  (interactive)
  (let ((out (generate-new-buffer " *cfengine format*" t))
        (coding-system-for-read 'utf-8)
        (coding-system-for-write 'utf-8))
    (unwind-protect
        (save-restriction
          (widen)
          (let ((status (call-process-region
                         nil nil cfengine-ts-mode-cfengine-program
                         nil (list out nil) nil "format" "-")))
            (unless (eql status 0)
              (user-error "Formatting failed: %s"
                          (with-current-buffer out
                            (string-trim (buffer-string)))))
            (unless (zerop (compare-buffer-substrings nil nil nil out nil nil))
              ;; Emacs 31 takes a buffer here and obsoletes the
              ;; Emacs 30 way.
              (if (>= emacs-major-version 31)
                  (replace-region-contents (point-min) (point-max) out)
                (with-no-warnings (replace-buffer-contents out))))))
      (kill-buffer out))))

(defun cfengine-ts-mode--format-before-save ()
  "Format the buffer if `cfengine-ts-mode-format-on-save' is non-nil.
A failure is reported but doesn't stop the save."
  (when cfengine-ts-mode-format-on-save
    (condition-case err
        (cfengine-ts-mode-format-buffer)
      (error (message "%s" (error-message-string err))))))

;;; Linting

(defvar-local cfengine-ts-mode--lint-process nil
  "The running `cfengine lint' process for this buffer.")

(defconst cfengine-ts-mode--lint-regexp
  (concat "^\\(Error\\|Deprecation\\|Convention\\): \\(.*\\)"
          " at \\(.+\\):\\([0-9]+\\):\\([0-9]+\\)$")
  "Regexp for a `cfengine lint' message.
Groups: kind, message, file, line and column (1-based).")

(defun cfengine-ts-mode--lint-region (source line column width)
  "Return (BEG . END) in SOURCE for LINE and 1-based COLUMN.
WIDTH is the length of the span, or nil for the rest of the symbol."
  (with-current-buffer source
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (forward-line (1- line))
        (let ((eol (line-end-position)))
          (forward-char (min (1- column) (- eol (point))))
          (let* ((beg (if (and (= (point) eol) (> eol (line-beginning-position)))
                          (1- (point))
                        (point)))
                 (end (cond (width (min eol (+ beg width)))
                            ((progn (goto-char beg)
                                    (skip-syntax-forward "w_")
                                    (> (point) beg))
                             (point))
                            (t (min eol (1+ beg))))))
            (cons beg (max end (min (1+ beg) (point-max))))))))))

(defun cfengine-ts-mode--lint-diagnostics (source file)
  "Parse `cfengine lint' output in the current buffer for SOURCE.
FILE is the copy of SOURCE that was linted."
  (let (diagnostics)
    (goto-char (point-min))
    (while (re-search-forward cfengine-ts-mode--lint-regexp nil t)
      (let ((kind (match-string 1))
            (message (match-string 2))
            (path (match-string 3))
            (line (string-to-number (match-string 4)))
            (column (string-to-number (match-string 5)))
            ;; The span is underlined as ^---^ on the line above.
            (width (save-excursion
                     (forward-line -1)
                     (and (looking-at "^ *\\(\\^\\(?:-*\\^\\)?\\) *$")
                          (length (match-string 1))))))
        (when (looking-at "\nHint: \\(.*\\)")
          (setq message (concat message ". " (match-string 1))))
        (when (equal (file-name-nondirectory path)
                     (file-name-nondirectory file))
          (let ((region (cfengine-ts-mode--lint-region
                         source line column width)))
            (push (flymake-make-diagnostic
                   source (car region) (cdr region)
                   (if (equal kind "Error") :error :warning)
                   message)
                  diagnostics)))))
    ;; Lint failed the file but we couldn't place why.
    (when (and (null diagnostics)
               (cfengine-ts-mode--lint-checked-p file "FAIL"))
      (push (cfengine-ts-mode--lint-line-1
             source :error (concat "cfengine lint failed: "
                                   (cfengine-ts-mode--lint-summary)))
            diagnostics))
    (nreverse diagnostics)))

(defun cfengine-ts-mode--lint-checked-p (file &optional result)
  "Non-nil if the lint output in the current buffer covers FILE.
Lint prints PASS or FAIL for each file it checks.  RESULT restricts
the match to one of those."
  (save-excursion
    (goto-char (point-min))
    (re-search-forward
     (concat "^" (or result "\\(?:PASS\\|FAIL\\)") ": .*"
             (regexp-quote (file-name-nondirectory file)))
     nil t)))

(defun cfengine-ts-mode--lint-summary ()
  "Return the first error in the lint output in the current buffer.
Fall back to the first non-empty line."
  (save-excursion
    (goto-char (point-min))
    (if (re-search-forward "^Error: .*" nil t)
        (match-string 0)
      (skip-chars-forward " \t\n")
      (buffer-substring (point) (line-end-position)))))

(defun cfengine-ts-mode--lint-line-1 (source type text)
  "Return a Flymake diagnostic of TYPE with TEXT on line 1 of SOURCE."
  (let ((region (cfengine-ts-mode--lint-region source 1 1 nil)))
    (flymake-make-diagnostic source (car region) (cdr region) type text)))

(defun cfengine-ts-mode--policy-root ()
  "Return the policy directory holding the visited file, or nil.
That is the nearest parent with promises.cf or promises.cf.in, as in
masterfiles."
  (and buffer-file-name
       (locate-dominating-file
        buffer-file-name
        (lambda (dir)
          (or (file-exists-p (expand-file-name "promises.cf" dir))
              (file-exists-p (expand-file-name "promises.cf.in" dir)))))))

(defun cfengine-ts-mode--lint-context ()
  "Return the other policy files to lint the buffer with.
These are the .cf files under `cfengine-ts-mode--policy-root', except
the visited file and anything in a hidden, tests or documentation
directory.  Hidden directories can hold whole copies of the tree (git
worktrees), and the examples in the others define bundles that would
clash with the real ones."
  ;; Expanded: the file names go to a process, not through a shell.
  (when-let* ((dir (cfengine-ts-mode--policy-root))
              (root (expand-file-name dir)))
    (let ((self (file-truename buffer-file-name)))
      (seq-remove (lambda (file) (equal (file-truename file) self))
                  (directory-files-recursively
                   root "\\.cf\\'" nil
                   (lambda (dir)
                     (let ((name (file-name-nondirectory dir)))
                       (not (or (string-prefix-p "." name)
                                (member name '("tests" "documentation")))))))))))

(defun cfengine-ts-mode--lint-start (source file context report-fn
                                         &optional note)
  "Lint FILE, a copy of SOURCE, with CONTEXT and pass results to REPORT-FN.
With CONTEXT, a list of the policy's other files, lint in strict mode;
if lint never gets to FILE, typically because a context file doesn't
parse, start over without CONTEXT.  Without it, turn strict mode off.
NOTE, if non-nil, is added to the results as a note on line 1."
  (with-current-buffer source
    (setq cfengine-ts-mode--lint-process
          (make-process
           :name "cfengine-lint"
           :noquery t
           :connection-type 'pipe
           :buffer (generate-new-buffer " *cfengine lint*" t)
           :command `(,cfengine-ts-mode-cfengine-program "lint"
                      ,@(unless context '("--strict" "no"))
                      ,@cfengine-ts-mode-lint-arguments ,file ,@context)
           :sentinel
           (lambda (proc _event)
             (when (memq (process-status proc) '(exit signal))
               (let ((retrying nil))
                 (unwind-protect
                     (if (not (and (buffer-live-p source)
                                   (eq proc (buffer-local-value
                                             'cfengine-ts-mode--lint-process
                                             source))))
                         (flymake-log :warning "Canceling obsolete check %s" proc)
                       (with-current-buffer (process-buffer proc)
                         (cond
                          ((cfengine-ts-mode--lint-checked-p file)
                           (funcall report-fn
                                    (append
                                     (and note
                                          (list (cfengine-ts-mode--lint-line-1
                                                 source :note note)))
                                     (cfengine-ts-mode--lint-diagnostics
                                      source file))))
                          (context
                           (setq retrying t)
                           (cfengine-ts-mode--lint-start
                            source file nil report-fn
                            (concat "Linted without the rest of the policy: "
                                    (cfengine-ts-mode--lint-summary))))
                          (t
                           (funcall report-fn
                                    (list (cfengine-ts-mode--lint-line-1
                                           source :error
                                           (concat "cfengine lint did not run: "
                                                   (cfengine-ts-mode--lint-summary)))))))))
                   (unless retrying (delete-file file))
                   (kill-buffer (process-buffer proc))))))))))

(defun cfengine-ts-mode-flymake (report-fn &rest _args)
  "Flymake backend running `cfengine lint' on a copy of the buffer.
REPORT-FN is the Flymake callback.

Inside a policy tree such as masterfiles, the copy is linted together
with the tree's other files in strict mode, so bundles and bodies from
the standard library and elsewhere resolve.  Otherwise it is linted on
its own with strict mode off, since those references can't be resolved.
See also `cfengine-ts-mode-lint-arguments'."
  (unless (executable-find cfengine-ts-mode-cfengine-program)
    (error "Cannot find %s" cfengine-ts-mode-cfengine-program))
  (when (process-live-p cfengine-ts-mode--lint-process)
    (kill-process cfengine-ts-mode--lint-process))
  ;; lint picks the file type from the name, so always use .cf.
  (let ((file (make-temp-file "cfengine-lint" nil ".cf"))
        (coding-system-for-write 'utf-8))
    (save-restriction
      (widen)
      (write-region nil nil file nil 'silent))
    (cfengine-ts-mode--lint-start (current-buffer) file
                                  (cfengine-ts-mode--lint-context)
                                  report-fn)))

;;;###autoload
(define-derived-mode cfengine-ts-mode prog-mode "CFEngine3[ts]"
  "Major mode for CFEngine 3 policy, powered by tree-sitter."
  :syntax-table cfengine3-mode-syntax-table
  ;; Settings shared with `cfengine3-mode' that don't depend on the parser.
  (cfengine-common-settings)
  (setq-local comment-end "")
  (setq-local prettify-symbols-alist cfengine3--prettify-symbols-alist)
  (when cfengine-cf-promises
    (setq-local compile-command
                (concat cfengine-cf-promises " -f "
                        (when buffer-file-name
                          (shell-quote-argument buffer-file-name)))))
  (add-hook 'eldoc-documentation-functions
            #'cfengine3-documentation-function nil t)
  (add-hook 'completion-at-point-functions
            #'cfengine-ts-mode--completion-at-point nil t)
  (add-hook 'flymake-diagnostic-functions #'cfengine-ts-mode-flymake nil t)
  (add-hook 'before-save-hook #'cfengine-ts-mode--format-before-save nil t)
  (when (treesit-ready-p 'cfengine)
    (treesit-parser-create 'cfengine)
    (setq-local indent-tabs-mode nil)
    (setq-local treesit-font-lock-settings cfengine-ts-mode--font-lock-settings
                treesit-font-lock-feature-list
                '((comment definition keyword)
                  (string guard preprocessor)
                  (property function variable)
                  (bracket delimiter operator error)))
    (setq-local treesit-simple-indent-rules cfengine-ts-mode--indent-rules)
    (setq-local treesit-defun-type-regexp
                (rx bos (or "bundle_block" "body_block" "promise_block") eos)
                treesit-defun-name-function #'cfengine-ts-mode--defun-name
                treesit-simple-imenu-settings
                '(("Bundle" "\\`bundle_block\\'" nil nil)
                  ("Body" "\\`body_block\\'" nil nil)
                  ("Promise type" "\\`promise_block\\'" nil nil)))
    (treesit-major-mode-setup)))

(derived-mode-add-parents 'cfengine-ts-mode '(cfengine3-mode))

;; Inlined rather than calling `cfengine-ts-mode--remap', so that
;; startup doesn't load the whole package.
;;;###autoload
(when (and (fboundp 'treesit-language-available-p)
           (treesit-language-available-p 'cfengine))
  (add-to-list 'major-mode-remap-defaults '(cfengine-mode . cfengine-ts-mode))
  (add-to-list 'major-mode-remap-defaults '(cfengine3-mode . cfengine-ts-mode)))

(provide 'cfengine-ts-mode)
;;; cfengine-ts-mode.el ends here
