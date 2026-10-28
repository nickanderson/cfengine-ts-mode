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
;; content: a `.cf' or `.cf.sub' file with a
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
(require 'xref)

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

(defvar cfengine-ts-mode-syntax-table
  (let ((table (make-syntax-table cfengine3-mode-syntax-table)))
    ;; `cfengine3-mode' only fills in its table when it runs, so do it
    ;; here: # comments and "..." and '...' strings.
    (cfengine-common-syntax table)
    ;; `...' strings too, which `cfengine3-mode' doesn't know.
    (modify-syntax-entry ?` "\"" table)
    table)
  "Syntax table for `cfengine-ts-mode'.")

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
The file name must end in .cf or .cf.sub, and the text
must contain a bundle, body or promise block header: the keyword, a
type and a name, then optionally a parameter list, an opening brace and
a comment, and nothing else on the line.  Keywords are case-sensitive,
as in CFEngine.  Intended for `magic-mode-alist'."
    (and buffer-file-name
         (string-match-p "\\.cf\\(?:\\.sub\\)?\\'" buffer-file-name)
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
   ;; A bare name as a value, or in a list value, refers to a bundle or
   ;; body (usebundle => helper, bundlesequence => { main }), like a call
   ;; without arguments.  As a call argument it names a variable instead.
   '((calling_identifier) @font-lock-function-call-face
     (attribute (qualified_identifier) @font-lock-function-call-face)
     (attribute (list (qualified_identifier) @font-lock-function-call-face)))

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

;; Indentation of incomplete code.  While a block is being typed it
;; doesn't parse, and blank lines have no node, so these rules work from
;; bracket depth and the previous line instead of the tree.

(defun cfengine-ts-mode--incomplete-p (node parent _bol)
  "Non-nil when NODE is missing or within a parse error under PARENT."
  (or (null node)
      (treesit-parent-until (or node parent)
                            (lambda (n) (equal (treesit-node-type n) "ERROR"))
                            t)))

(defun cfengine-ts-mode--indentation-at (pos)
  "Return the indentation of the line holding POS."
  (save-excursion (goto-char pos) (current-indentation)))

(defun cfengine-ts-mode--code-end ()
  "Return the end of the code on the current line, before any comment."
  (save-excursion
    (let ((ppss (syntax-ppss (line-end-position))))
      (goto-char (if (nth 4 ppss) (nth 8 ppss) (line-end-position)))
      (skip-chars-backward " \t")
      (point))))

(defun cfengine-ts-mode--code-line-p ()
  "Non-nil if the current line holds code: not blank, comment or macro."
  (save-excursion
    (back-to-indentation)
    (not (or (eolp) (looking-at-p "[#@]")))))

(defconst cfengine-ts-mode--section-re
  "[[:alnum:]_]+:[ \t]*\\(?:#.*\\)?$"
  "Regexp for a section header such as \"vars:\", from indentation.")

(defconst cfengine-ts-mode--class-guard-re
  "[^\"#\n]*::[ \t]*\\(?:#.*\\)?$"
  "Regexp for a class guard such as \"linux::\", from indentation.")

(defun cfengine-ts-mode--stakeholder-open-p (open)
  "Non-nil if OPEN is the opening brace of a promise's stakeholders (->)."
  (save-excursion
    (goto-char open)
    (looking-back "->[ \t]*" (line-beginning-position))))

(defun cfengine-ts-mode--bundle-brace-p (open)
  "Non-nil if OPEN, a block's opening brace, belongs to a bundle."
  (save-excursion
    (goto-char open)
    (when (looking-back "^[ \t]*" (line-beginning-position))
      ;; The brace is on its own line: the header is the code above.
      (forward-line -1)
      (while (and (not (bobp)) (not (cfengine-ts-mode--code-line-p)))
        (forward-line -1)))
    (back-to-indentation)
    (looking-at-p "bundle\\_>")))

(defun cfengine-ts-mode--statement-line ()
  "Move to the line where the statement on the current line starts.
That is the line of the opening bracket for a line starting with a
closing one, or the first line of a string continued onto this line."
  (back-to-indentation)
  (let ((ppss (syntax-ppss)))
    (cond ((nth 3 ppss) (goto-char (nth 8 ppss)))
          ((and (memq (char-after) '(?\} ?\))) (nth 1 ppss))
           (goto-char (nth 1 ppss)))))
  (back-to-indentation))

(defun cfengine-ts-mode--next-code-indentation ()
  "Return the indentation of the next code line in the same block, or nil.
Nil too when that line closes the block or list."
  (save-excursion
    (let ((depth (car (syntax-ppss (line-beginning-position)))))
      (forward-line 1)
      (while (and (not (eobp)) (not (cfengine-ts-mode--code-line-p)))
        (forward-line 1))
      (back-to-indentation)
      (and (not (eobp))
           (not (memq (char-after) '(?\} ?\))))
           (= (car (syntax-ppss)) depth)
           (current-indentation)))))

(defun cfengine-ts-mode--indent-line ()
  "Indent the current line, then the comments just above it.
A comment's indentation follows the code after it, so indenting a code
line can move the comments that lead up to it."
  (prog1 (treesit-indent)
    (when (cfengine-ts-mode--code-line-p)
      (save-excursion
        (forward-line -1)
        (while (and (not (bobp))
                    (looking-at-p "^[ \t]*\\(?:#\\|$\\)"))
          (unless (looking-at-p "^[ \t]*$")
            (treesit-indent))
          (forward-line -1))))))

(defun cfengine-ts-mode--guess-column (_node _parent bol)
  "Return a column for the line at BOL from bracket depth and context."
  (save-excursion
    (goto-char bol)
    (skip-chars-forward " \t")
    (let* ((off cfengine-ts-mode-indent-offset)
           (ppss (syntax-ppss))
           (depth (car ppss))
           (open (nth 1 ppss)))
      (cond
       ;; Inside a string the leading whitespace is content.
       ((nth 3 ppss) (current-indentation))
       ;; A closing bracket lines up with the line that opened it, or
       ;; one level in for stakeholders as `cfengine format' does.
       ((memq (char-after) '(?\} ?\)))
        (if (null open) 0
          (+ (cfengine-ts-mode--indentation-at open)
             (if (cfengine-ts-mode--stakeholder-open-p open) off 0))))
       ((or (<= depth 0) (null open)) 0)
       ;; In a list or call: one level in, two for stakeholders as
       ;; `cfengine format' does.
       ;; A comment goes with the code after it, as in `cfengine format'.
       ((and (looking-at-p "#") (cfengine-ts-mode--next-code-indentation)))
       ((>= depth 2)
        (+ (cfengine-ts-mode--indentation-at open)
           (if (cfengine-ts-mode--stakeholder-open-p open) (* 2 off) off)))
       (t
        (let ((bundle (cfengine-ts-mode--bundle-brace-p open)))
          (cond
           ((looking-at-p cfengine-ts-mode--class-guard-re)
            (if bundle (* 2 off) off))
           ((looking-at-p cfengine-ts-mode--section-re) off)
           (t (cfengine-ts-mode--guess-from-previous bol open bundle)))))))))

(defun cfengine-ts-mode--guess-from-previous (bol open bundle)
  "Return a column for BOL from the previous code line in its block.
OPEN is the block's opening brace; BUNDLE is non-nil in a bundle."
  (let ((off cfengine-ts-mode-indent-offset))
    (save-excursion
      (goto-char bol)
      (let ((found nil))
        (while (and (not found)
                    (zerop (forward-line -1))
                    (> (line-end-position) open))
          (when (and (cfengine-ts-mode--code-line-p)
                     (> (point) (save-excursion (goto-char open)
                                                (line-end-position))))
            (setq found t)))
        (if (not found)
            off
          (back-to-indentation)
          (let ((last (char-before (cfengine-ts-mode--code-end))))
            (cond
             ((or (looking-at-p cfengine-ts-mode--section-re)
                  (looking-at-p cfengine-ts-mode--class-guard-re))
              (+ (current-indentation) off))
             (t
              (cfengine-ts-mode--statement-line)
              (let ((promiser (and bundle (memq (char-after) '(?\" ?\' ?`))))
                    (column (current-indentation)))
                (cond
                 ;; A promise or body attribute ended.
                 ((eq last ?\;)
                  (if (and bundle (not promiser)) (- column off) column))
                 ;; Another attribute follows.
                 ((eq last ?,) (if promiser (+ column off) column))
                 ;; A promiser waiting for its attributes.
                 (promiser (+ column off))
                 (t column)))))))))))

(defvar cfengine-ts-mode--indent-rules
  ;; Node-type matchers are regexps, so anchor them: "promise" would
  ;; otherwise also match "class_guarded_promises".
  `((cfengine
     (cfengine-ts-mode--inside-string-p cfengine-ts-mode--bol 0)
     ((node-is ,(rx bos "macro" eos)) column-0 0)
     ;; While typing, the tree is incomplete: guess from the text.
     (cfengine-ts-mode--incomplete-p column-0 cfengine-ts-mode--guess-column)
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

(defun cfengine-ts-mode--body-attribute-p (node)
  "Non-nil if NODE is an attribute of a body or custom promise type block.
In bundles, attributes belong to promises."
  (and (equal (treesit-node-type node) "attribute")
       (not (member (treesit-node-type (treesit-node-parent node))
                    '("promise" "half_promise")))))

(defun cfengine-ts-mode--forward-sentence (&optional arg)
  "Move forward ARG promises, or body attributes, like `forward-sentence'.
A body attribute's \";\" lies outside its node; step over it, so that
point ends up after the \";\" as it does for a promise."
  (setq arg (or arg 1))
  (treesit-forward-sentence arg)
  (when (and (> arg 0) (eq (char-after) ?\;))
    (forward-char)))

;;; Formatting

(defun cfengine-ts-mode--format-into (out &optional text)
  "Run `cfengine format' on TEXT, or on the whole buffer, into buffer OUT.
Signal a `user-error' with the formatter's message if it fails."
  (let ((coding-system-for-read 'utf-8)
        (coding-system-for-write 'utf-8))
    (save-restriction
      (widen)
      (unless (eql 0 (call-process-region
                      text nil cfengine-ts-mode-cfengine-program
                      nil (list out nil) nil "format" "-"))
        (user-error "Formatting failed: %s"
                    (with-current-buffer out (string-trim (buffer-string))))))))

(defun cfengine-ts-mode--replace-with (beg end out)
  "Replace BEG..END with the contents of buffer OUT, keeping what's equal.
Only the differing parts change, so point and marks are kept."
  (save-restriction
    (narrow-to-region beg end)
    (unless (zerop (compare-buffer-substrings nil nil nil out nil nil))
      ;; Emacs 31 takes a buffer here and obsoletes the Emacs 30 way.
      (if (>= emacs-major-version 31)
          (replace-region-contents (point-min) (point-max) out)
        (with-no-warnings (replace-buffer-contents out))))))

(defun cfengine-ts-mode-format-buffer ()
  "Format the buffer with `cfengine format'.
Only the changed regions are replaced, so point and marks are kept.
If the policy can't be parsed, the buffer is left alone."
  (interactive)
  (let ((out (generate-new-buffer " *cfengine format*" t)))
    (unwind-protect
        (save-restriction
          (widen)
          (cfengine-ts-mode--format-into out)
          (cfengine-ts-mode--replace-with (point-min) (point-max) out))
      (kill-buffer out))))

(defun cfengine-ts-mode--blocks-in (beg end)
  "Return the top-level bundle, body and promise blocks touching BEG..END.
When BEG equals END, return the block containing it, if any."
  (seq-filter
   (lambda (node)
     (and (member (treesit-node-type node)
                  '("bundle_block" "body_block" "promise_block"))
          (if (= beg end)
              (<= (treesit-node-start node) beg (treesit-node-end node))
            (and (< (treesit-node-start node) end)
                 (> (treesit-node-end node) beg)))))
   (treesit-node-children (treesit-buffer-root-node 'cfengine) t)))

(defun cfengine-ts-mode-format-region (beg end)
  "Format the blocks between BEG and END with `cfengine format'.
`cfengine format' only accepts complete policy, so the region grows to
the whole bundle, body and promise blocks it touches; text between
blocks is left alone.  Interactively, without an active region, format
the block at point.  If any block can't be parsed, nothing changes."
  (interactive (if (use-region-p)
                   (list (region-beginning) (region-end))
                 (list (point) (point))))
  (let ((blocks (cfengine-ts-mode--blocks-in beg end))
        formatted)
    (unless blocks
      (user-error "No bundle, body or promise block here"))
    (unwind-protect
        (progn
          ;; Format every block before changing any.
          (dolist (node blocks)
            (let ((out (generate-new-buffer " *cfengine format*" t)))
              (push (list (treesit-node-start node) (treesit-node-end node) out)
                    formatted)
              (cfengine-ts-mode--format-into
               out (concat (treesit-node-text node t) "\n"))
              ;; The block ends at its "}", without the newline.
              (with-current-buffer out
                (goto-char (point-max))
                (when (eq (char-before) ?\n)
                  (delete-char -1)))))
          ;; `formatted' runs last block first, so earlier positions
          ;; stay valid as later blocks change.
          (pcase-dolist (`(,start ,stop ,out) formatted)
            (cfengine-ts-mode--replace-with start stop out)))
      (pcase-dolist (`(,_ ,_ ,out) formatted)
        (kill-buffer out)))))

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
      ;; Skip dotfiles such as Emacs lock files (.#main.cf, a symlink to
      ;; nowhere) and anything else that isn't a readable regular file.
      (seq-remove (lambda (file)
                    (or (equal (file-truename file) self)
                        (not (file-regular-p file))
                        (not (file-readable-p file))))
                  (directory-files-recursively
                   root "\\`[^.].*\\.cf\\'" nil
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

;;; Flycheck

(declare-function flycheck-define-generic-checker "ext:flycheck")
(declare-function flycheck-error-new-at-pos "ext:flycheck")
(defvar flycheck-checkers)

(defun cfengine-ts-mode--flycheck-start (checker callback)
  "Start `cfengine lint' for Flycheck CHECKER, reporting to CALLBACK.
Runs the same check as `cfengine-ts-mode-flymake' and converts the
results."
  (let ((source (current-buffer))
        (file (make-temp-file "cfengine-lint" nil ".cf"))
        (coding-system-for-write 'utf-8))
    (save-restriction
      (widen)
      (write-region nil nil file nil 'silent))
    (cfengine-ts-mode--lint-start
     source file (cfengine-ts-mode--lint-context)
     (lambda (diagnostics)
       (funcall callback 'finished
                (with-current-buffer source
                  (mapcar
                   (lambda (d)
                     (flycheck-error-new-at-pos
                      (flymake-diagnostic-beg d)
                      (pcase (flymake-diagnostic-type d)
                        (:error 'error) (:warning 'warning) (_ 'info))
                      (flymake-diagnostic-text d)
                      :end-pos (flymake-diagnostic-end d)
                      :checker checker))
                   diagnostics)))))
    cfengine-ts-mode--lint-process))

(defun cfengine-ts-mode--flycheck-interrupt (_checker process)
  "Stop the `cfengine lint' PROCESS of a Flycheck check."
  (when (process-live-p process)
    (kill-process process)))

;;;###autoload
(defun cfengine-ts-mode-flycheck-setup ()
  "Define and register the `cfengine-lint' Flycheck checker.
It runs the same check as `cfengine-ts-mode-flymake'.  This happens by
itself when `cfengine-ts-mode' starts with Flycheck already loaded;
otherwise call it once, for example from `flycheck-mode-hook'."
  (require 'flycheck)
  (flycheck-define-generic-checker 'cfengine-lint
    "CFEngine policy checker using `cfengine lint'.
See `cfengine-ts-mode-flymake' for how the rest of the policy is used."
    :start #'cfengine-ts-mode--flycheck-start
    :interrupt #'cfengine-ts-mode--flycheck-interrupt
    :modes '(cfengine-ts-mode)
    :predicate (lambda ()
                 (executable-find cfengine-ts-mode-cfengine-program)))
  (add-to-list 'flycheck-checkers 'cfengine-lint))

;;; Completion and ElDoc for promise types, attributes and values
;;
;; These read the syntax description from `cf-promises' (see
;; `cfengine3-make-syntax-cache') and work out the context from the text,
;; so they work on code that doesn't parse yet.

(defun cfengine-ts-mode--syntax (&rest path)
  "Return the entry at PATH, a list of keys, in the `cf-promises' syntax."
  (let ((node (cfengine3-make-syntax-cache)))
    (dolist (key path node)
      (setq node (cdr (assq (if (stringp key) (intern key) key) node))))))

(defun cfengine-ts-mode--block-header (open)
  "Return (KIND TYPE NAME) for the block whose opening brace is at OPEN.
KIND is \"bundle\", \"body\" or \"promise\"; NAME is nil if not typed yet."
  (save-excursion
    (goto-char open)
    (when (looking-back "^[ \t]*" (line-beginning-position))
      (forward-line -1)
      (while (and (not (bobp)) (not (cfengine-ts-mode--code-line-p)))
        (forward-line -1)))
    (back-to-indentation)
    (when (looking-at "\\(bundle\\|body\\|promise\\)[ \t]+\\([[:alnum:]_]+\\)\\(?:[ \t]+\\([[:alnum:]_]+\\)\\)?")
      (list (match-string-no-properties 1) (match-string-no-properties 2)
            (match-string-no-properties 3)))))

(defun cfengine-ts-mode--section (open)
  "Return the promise type of the section around point, after OPEN."
  (save-excursion
    (let (section)
      (while (and (not section)
                  (re-search-backward
                   "^[ \t]*\\([[:alnum:]_]+\\):[ \t]*\\(?:#.*\\)?$" open t))
        (unless (nth 8 (syntax-ppss))
          (setq section (match-string-no-properties 1))))
      section)))

(defun cfengine-ts-mode--context ()
  "Return the CFEngine context at point as a plist, or nil.
Keys: :block (KIND TYPE), :name (the block's), :section, :depth,
:string, and :attribute when point is in an attribute's value."
  (let* ((ppss (syntax-ppss))
         (open (car (nth 9 ppss))))
    (when open
      (save-excursion
        (let* ((header (cfengine-ts-mode--block-header open))
               (attribute
                (save-excursion
                  (when (nth 3 ppss) (goto-char (nth 8 ppss)))
                  (skip-syntax-backward "w_")
                  (skip-chars-backward " \t")
                  ;; Directly after "NAME =>", or in a list or call after it.
                  (when (or (looking-back "=>" (- (point) 2))
                            (and (> (car (syntax-ppss)) 1)
                                 (progn (goto-char (nth 1 (syntax-ppss)))
                                        (skip-chars-backward " \t")
                                        (or (looking-back "=>" (- (point) 2))
                                            (progn (skip-syntax-backward "w_")
                                                   (skip-chars-backward " \t")
                                                   (looking-back "=>" (- (point) 2)))))))
                    (backward-char 2)
                    (skip-chars-backward " \t")
                    (let ((end (point)))
                      (skip-syntax-backward "w_")
                      (buffer-substring-no-properties (point) end))))))
          (list :block (seq-take header 2)
                :name (nth 2 header)
                :section (and (equal (car header) "bundle")
                              (cfengine-ts-mode--section open))
                :depth (car ppss)
                :string (nth 3 ppss)
                :attribute attribute))))))

(defconst cfengine-ts-mode--promise-block-attributes
  '((path (type . "string") (range . "") (status . "normal"))
    (interpreter (type . "string") (range . "") (status . "normal")))
  "Syntax entries of the attributes of a custom promise type block.")

(defun cfengine-ts-mode--common-attributes ()
  "Return the syntax entries of the attributes every promise type allows."
  (let ((types (cfengine-ts-mode--syntax 'promiseTypes)))
    (seq-filter (lambda (attribute)
                  (seq-every-p (lambda (type)
                                 (assq (car attribute)
                                       (cdr (assq 'attributes (cdr type)))))
                               types))
                (cdr (assq 'attributes (cdar types))))))

(defun cfengine-ts-mode--custom-promise-types (bundle-type)
  "Return the custom promise types defined for bundles of BUNDLE-TYPE.
These are the promise blocks in the buffer and its policy tree."
  (seq-uniq (mapcan (lambda (d)
                      (and (equal (car d) "promise") (equal (nth 1 d) bundle-type)
                           (list (nth 2 d))))
                    (cfengine-ts-mode--definitions))))

(defun cfengine-ts-mode--custom-attributes-used (type)
  "Return the attribute names used in the buffer's sections of TYPE."
  (let (names)
    (dolist (section (treesit-query-capture
                      'cfengine '((bundle_section (promise_guard) @guard))
                      nil nil t))
      (when (equal (string-trim (treesit-node-text section t) nil "[ \t:]+")
                   type)
        (dolist (name (treesit-query-capture (treesit-node-parent section)
                                             '((attribute_name) @name)
                                             nil nil t))
          (push (treesit-node-text name t) names))))
    (seq-uniq (nreverse names))))

(defun cfengine-ts-mode--attributes (context)
  "Return the syntax entries of the attributes allowed in CONTEXT.
In a section of a custom promise type, those are the attributes every
promise type allows and the ones already used with it in the buffer."
  (pcase (plist-get context :block)
    (`("bundle" ,type)
     (when-let* ((section (plist-get context :section)))
       (or (cfengine-ts-mode--syntax 'promiseTypes section 'attributes)
           (when (member section (cfengine-ts-mode--custom-promise-types type))
             (let ((common (cfengine-ts-mode--common-attributes)))
               (append common
                       (mapcan (lambda (name)
                                 (unless (assq (intern name) common)
                                   (list (list (intern name)
                                               '(type . "custom")
                                               '(status . "normal")))))
                               (cfengine-ts-mode--custom-attributes-used
                                section))))))))
    (`("body" ,type)
     (cfengine-ts-mode--syntax 'bodyTypes type 'attributes))
    (`("promise" ,_) cfengine-ts-mode--promise-block-attributes)))

(defun cfengine-ts-mode--attribute (context name)
  "Return the syntax entry of attribute NAME in CONTEXT, or nil."
  (cdr (assq (intern name) (cfengine-ts-mode--attributes context))))

(defvar cfengine-ts-mode--definitions-cache (make-hash-table :test #'equal)
  "Definitions per policy file: FILE -> (MTIME . DEFINITIONS).")

(defconst cfengine-ts-mode--definition-re
  (rx bol (* blank)
      (or (seq (group-n 1 (or "bundle" "body" "promise")) (+ blank)
               (group-n 2 (+ (in alnum "_"))) (+ blank)
               (group-n 3 (+ (in alnum "_"))))
          (seq (group-n 4 (+ (in alnum "_"))) ":" (* blank) (or "#" eol))
          (seq "\"" (group-n 5 (+ (in alnum "_"))) (in "\"["))))
  "Match a block header, a section header or a promiser.")

(defun cfengine-ts-mode--scan-definitions ()
  "Return the blocks, block parameters, variables and classes in the buffer.
Each is (KIND TYPE NAME LINE COLUMN), the position being the name's.
For a block KIND is \"bundle\", \"body\" or \"promise\" and TYPE its
type.  For a parameter, or a variable or class promised in a bundle's
vars: or classes: section, KIND is \"parameter\", \"vars\" or
\"classes\" and TYPE is the name of its block.  The buffer must use
`cfengine-ts-mode-syntax-table'."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (let (definitions block bundle section)
        (cl-flet ((add (kind type group)
                    (push (list kind type (match-string-no-properties group)
                                (line-number-at-pos (match-beginning group) t)
                                (save-excursion (goto-char (match-beginning group))
                                                (current-column)))
                          definitions)))
          (while (re-search-forward cfengine-ts-mode--definition-re nil t)
            (let ((ppss (save-match-data
                          (save-excursion (syntax-ppss (match-beginning 0))))))
              (cond
               ((nth 8 ppss))
               ((match-beginning 1)
                (add (match-string-no-properties 1) (match-string-no-properties 2) 3)
                (setq block (match-string-no-properties 3)
                      bundle (equal (match-string 1) "bundle")
                      section nil)
                (when (looking-at "[ \t]*(")
                  (goto-char (match-end 0))
                  (while (re-search-forward "\\=[ \t\n,]*\\([[:alnum:]_]+\\)" nil t)
                    (add "parameter" block 1))))
               ((/= (car ppss) 1))
               ((match-beginning 4) (setq section (match-string-no-properties 4)))
               ((and bundle (member section '("vars" "classes"))
                     ;; A promiser, not a value on a continuation line.
                     (save-excursion (goto-char (match-beginning 0))
                                     (forward-comment (- (point)))
                                     (memq (char-before) '(?\; ?{ ?:))))
                (add section block 5)))))
          (nreverse definitions))))))

(defun cfengine-ts-mode--policy-sources ()
  "Return the current buffer and the other files of its policy tree.
A file visited in a buffer with unsaved changes is given as that buffer."
  (cons (current-buffer)
        (mapcar (lambda (file)
                  (let ((buffer (get-file-buffer file)))
                    (if (and buffer (buffer-modified-p buffer)) buffer file)))
                (cfengine-ts-mode--lint-context))))

(defun cfengine-ts-mode--file-definitions (file)
  "Return the block headers in FILE, cached by modification time."
  (let ((mtime (file-attribute-modification-time (file-attributes file)))
        (cached (gethash file cfengine-ts-mode--definitions-cache)))
    (if (and cached (equal (car cached) mtime))
        (cdr cached)
      (let ((definitions
             ;; The file may be gone since the directory was listed.
             (ignore-error file-missing
               (with-temp-buffer
                 (insert-file-contents file)
                 (set-syntax-table cfengine-ts-mode-syntax-table)
                 (cfengine-ts-mode--scan-definitions)))))
        (puthash file (cons mtime definitions)
                 cfengine-ts-mode--definitions-cache)
        definitions))))

(defvar-local cfengine-ts-mode--buffer-definitions nil
  "The buffer's definitions, as (MODIFICATION-TICK . DEFINITIONS).")

(defun cfengine-ts-mode--buffer-definitions ()
  "Return the definitions in the current buffer, cached until it changes."
  (let ((tick (buffer-chars-modified-tick)))
    (if (eql (car cfengine-ts-mode--buffer-definitions) tick)
        (cdr cfengine-ts-mode--buffer-definitions)
      (cdr (setq cfengine-ts-mode--buffer-definitions
                 (cons tick (cfengine-ts-mode--scan-definitions)))))))

(defun cfengine-ts-mode--definitions ()
  "Return the definitions in the buffer and its policy tree.
Each is (KIND TYPE NAME LINE COLUMN SOURCE), as from
`cfengine-ts-mode--scan-definitions', SOURCE being a buffer or a file
name."
  (mapcan (lambda (source)
            (mapcar (lambda (d) (append d (list source)))
                    (if (bufferp source)
                        (with-current-buffer source
                          (cfengine-ts-mode--buffer-definitions))
                      (cfengine-ts-mode--file-definitions source))))
          (cfengine-ts-mode--policy-sources)))

(defun cfengine-ts-mode--value-candidates (entry name)
  "Return completions for the value of attribute NAME described by ENTRY."
  (pcase (cdr (assq 'type entry))
    ("option" (split-string (cdr (assq 'range entry)) "," t))
    ("body"
     (seq-uniq (mapcan (lambda (d)
                         (and (equal (car d) "body") (equal (nth 1 d) name)
                              (list (nth 2 d))))
                       (cfengine-ts-mode--definitions))))
    ("bundle"
     (let ((type (if (member name '("edit_line" "edit_xml")) name "agent")))
       (seq-uniq (mapcan (lambda (d)
                           (and (equal (car d) "bundle") (equal (nth 1 d) type)
                                (list (nth 2 d))))
                         (cfengine-ts-mode--definitions)))))))

(defun cfengine-ts-mode--statement-start-p (open)
  "Non-nil if a new statement starts at point, in the block opened at OPEN.
That is after a section header, a class guard, a finished statement or
the block's brace, rather than in a promise awaiting more attributes."
  (save-excursion
    (let ((found nil))
      (while (and (not found) (zerop (forward-line -1))
                  (> (line-end-position) open))
        (setq found (and (cfengine-ts-mode--code-line-p)
                         (> (point) (save-excursion (goto-char open)
                                                    (line-end-position))))))
      (or (not found)
          (progn (back-to-indentation)
                 (or (looking-at-p cfengine-ts-mode--section-re)
                     (looking-at-p cfengine-ts-mode--class-guard-re)
                     (eq (char-before (cfengine-ts-mode--code-end)) ?\;)))))))

(defun cfengine-ts-mode--annotate (table)
  "Return an annotation function for candidates from syntax TABLE."
  (lambda (candidate)
    (when-let* ((entry (cdr (assq (intern candidate) table)))
                (type (cdr (assq 'type entry))))
      (concat " " type
              (unless (equal (cdr (assq 'status entry)) "normal")
                (concat " (" (cdr (assq 'status entry)) ")"))))))

(defun cfengine-ts-mode--syntax-completion-at-point ()
  "Complete promise types, attributes and attribute values at point."
  (when-let* ((context (and (not (nth 4 (syntax-ppss)))
                            (cfengine-ts-mode--context))))
    (let* ((in-string (plist-get context :string))
           (beg (save-excursion
                  (if in-string
                      (goto-char (1+ (nth 8 (syntax-ppss))))
                    (skip-syntax-backward "w_"))
                  (point)))
           (end (if in-string
                    (point)
                  (save-excursion (skip-syntax-forward "w_") (point))))
           (attribute (plist-get context :attribute)))
      (cond
       ;; A value.
       (attribute
        (when-let* ((entry (cfengine-ts-mode--attribute context attribute))
                    (candidates (cfengine-ts-mode--value-candidates
                                 entry attribute)))
          (list beg end candidates :exclusive 'no)))
       (in-string nil)
       ((/= (plist-get context :depth) 1) nil)
       ;; A section at the start of a statement in a bundle.
       ((and (equal (car (plist-get context :block)) "bundle")
             (save-excursion (goto-char beg)
                             (looking-back "^[ \t]*" (line-beginning-position)))
             (save-excursion (goto-char beg)
                             (cfengine-ts-mode--statement-start-p
                              (car (nth 9 (syntax-ppss)))))
             (not (looking-at-p "[[:alnum:]_]*:")))
        (let* ((bundle-type (nth 1 (plist-get context :block)))
               (custom (cfengine-ts-mode--custom-promise-types bundle-type))
               (types (append (cfengine-ts-mode--syntax
                               'bundleTypes bundle-type 'promiseTypes)
                              custom)))
          (when types
            (list beg end types
                  :exclusive 'no
                  :annotation-function
                  (lambda (candidate)
                    (if (member candidate custom)
                        " custom promise type"
                      " promise type"))
                  :exit-function
                  (lambda (_ status)
                    (when (eq status 'finished)
                      (unless (eq (char-after) ?:) (insert ":"))
                      (indent-according-to-mode)))))))
       ;; An attribute.
       (t
        (when-let* ((table (cfengine-ts-mode--attributes context)))
          (list beg end (mapcar (lambda (a) (symbol-name (car a))) table)
                :exclusive 'no
                :annotation-function (cfengine-ts-mode--annotate table)
                :exit-function
                (lambda (_ status)
                  (when (and (eq status 'finished)
                             (not (looking-at-p "[ \t]*=>")))
                    (insert " => "))))))))))

;;; Completion of variables and classes

(defvar cfengine-ts-mode--builtins-cache nil
  "Alist of `cfengine-cf-promises' values to the built-ins they report.")

(defun cfengine-ts-mode--builtins ()
  "Return (VARIABLES . CLASSES), the built-ins `cf-promises' reports.
VARIABLES are named with their scope, as \"sys.arch\"; CLASSES are
this host's hard classes.  Both are nil without `cf-promises'."
  (when cfengine-cf-promises
    (or (cdr (assoc cfengine-cf-promises cfengine-ts-mode--builtins-cache))
        (let ((file (make-temp-file "cfengine-ts-mode" nil ".cf"
                                    "bundle agent main\n{\n}\n")))
          (unwind-protect
              (cl-flet ((names (option)
                          (with-temp-buffer
                            (when (eql 0 (ignore-errors
                                           (call-process cfengine-cf-promises nil
                                                         '(t nil) nil
                                                         option "-f" file)))
                              (goto-char (point-min))
                              ;; Skip the column headings.
                              (forward-line 1)
                              (let (names)
                                (while (re-search-forward
                                        "^\\(?:default:\\)?\\([^ \t\n[]+\\)" nil t)
                                  (push (match-string-no-properties 1) names))
                                (seq-uniq (nreverse names)))))))
                (let ((builtins (cons (names "--show-vars")
                                      (names "--show-classes"))))
                  (push (cons cfengine-cf-promises builtins)
                        cfengine-ts-mode--builtins-cache)
                  builtins))
            (delete-file file))))))

(defconst cfengine-ts-mode--this-variables
  '("bundle" "handle" "namespace" "promise_dirname" "promise_filename"
    "promise_linenumber" "promiser" "promiser_gid" "promiser_pid"
    "promiser_ppid" "promiser_uid" "service_policy")
  "Variables of the this scope, which the agent sets for each promise.")

(defun cfengine-ts-mode--reference-bounds ()
  "Return (BEG END OPEN) of the variable name in $(...) or ${...} at point.
OPEN is the opening bracket character.  Return nil elsewhere."
  (let ((beg (save-excursion (skip-chars-backward "[:alnum:]_.:") (point)))
        (end (save-excursion (skip-chars-forward "[:alnum:]_.:") (point))))
    (when (and (> beg (1+ (point-min)))
               (memq (char-before beg) '(?\( ?{))
               (memq (char-before (1- beg)) '(?$ ?@)))
      (list beg end (char-before beg)))))

(defun cfengine-ts-mode--uniq-candidates (candidates)
  "Return CANDIDATES, (NAME . ANNOTATION) pairs, keeping each NAME's first."
  (let ((seen (make-hash-table :test #'equal)))
    (seq-filter (lambda (c)
                  (unless (gethash (car c) seen)
                    (puthash (car c) t seen)))
                candidates)))

(defun cfengine-ts-mode--annotations (candidates)
  "Return an annotation function for CANDIDATES, (NAME . ANNOTATION) pairs."
  (let ((annotations (make-hash-table :test #'equal)))
    (dolist (c candidates)
      (puthash (car c) (cdr c) annotations))
    (lambda (candidate) (gethash candidate annotations))))

(defun cfengine-ts-mode--variable-candidates (block)
  "Return (NAME . ANNOTATION) for the variables to offer in BLOCK.
Those are BLOCK's parameters and variables, BUNDLE.NAME for every
bundle's variables, and the built-in ones."
  (let (candidates)
    (dolist (d (cfengine-ts-mode--definitions))
      (pcase-let ((`(,kind ,type ,name . ,_) d))
        (when (and (member kind '("vars" "parameter")) (equal type block))
          (push (cons name (concat " " kind)) candidates))
        (when (equal kind "vars")
          (push (cons (concat type "." name) " vars") candidates))))
    (dolist (name (car (cfengine-ts-mode--builtins)))
      (push (cons name " built-in") candidates))
    (dolist (name cfengine-ts-mode--this-variables)
      (push (cons (concat "this." name) " built-in") candidates))
    (cfengine-ts-mode--uniq-candidates (nreverse candidates))))

(defun cfengine-ts-mode--variable-completion-at-point ()
  "Complete the variable name in a $(...) or ${...} reference at point."
  (when-let* ((bounds (and (not (nth 4 (syntax-ppss)))
                           (cfengine-ts-mode--reference-bounds)))
              (candidates (cfengine-ts-mode--variable-candidates
                           (plist-get (cfengine-ts-mode--context) :name))))
    (pcase-let ((`(,beg ,end ,open) bounds))
      (list beg end candidates
            :exclusive 'no
            :annotation-function
            (cfengine-ts-mode--annotations candidates)
            :exit-function
            (lambda (_ status)
              (let ((close (if (eq open ?\() ?\) ?})))
                (when (and (eq status 'finished)
                           (not (eq (char-after) close)))
                  (insert close))))))))

(defconst cfengine-ts-mode--class-attributes
  '("if" "unless" "ifvarclass" "expression" "and" "or" "xor" "not")
  "Attributes whose values are class expressions.")

(defun cfengine-ts-mode--class-candidates ()
  "Return (NAME . ANNOTATION) for the classes of the policy and the host."
  (let (candidates)
    (dolist (d (cfengine-ts-mode--definitions))
      (when (equal (car d) "classes")
        (push (cons (nth 2 d) (concat " class in " (nth 1 d))) candidates)))
    (dolist (name (cdr (cfengine-ts-mode--builtins)))
      (push (cons name " hard class") candidates))
    (cfengine-ts-mode--uniq-candidates (nreverse candidates))))

(defun cfengine-ts-mode--class-completion-at-point ()
  "Complete a class name in a class guard or a class expression's value."
  (when-let* ((context (and (not (nth 4 (syntax-ppss)))
                            (cfengine-ts-mode--context)))
              (beg (save-excursion (skip-chars-backward "[:alnum:]_") (point)))
              ((if (plist-get context :string)
                   (member (plist-get context :attribute)
                           cfengine-ts-mode--class-attributes)
                 ;; A class guard being typed: only class expression
                 ;; characters from the start of a statement.
                 (and (= (plist-get context :depth) 1)
                      (member (car (plist-get context :block)) '("bundle" "body"))
                      (save-excursion
                        (goto-char beg)
                        (skip-chars-backward "[:alnum:]_.|&!() \t")
                        (and (bolp)
                             (cfengine-ts-mode--statement-start-p
                              (car (nth 9 (syntax-ppss)))))))))
              (candidates (cfengine-ts-mode--class-candidates)))
    (list beg (save-excursion (skip-chars-forward "[:alnum:]_") (point))
          candidates
          :exclusive 'no
          :annotation-function
          (cfengine-ts-mode--annotations candidates))))

(defun cfengine-ts-mode--describe-attribute (name entry)
  "Return a one-line description of attribute NAME from syntax ENTRY."
  (let ((type (cdr (assq 'type entry)))
        (range (cdr (assq 'range entry)))
        (status (cdr (assq 'status entry))))
    (concat (propertize name 'face 'font-lock-property-name-face) ": "
            (propertize type 'face 'font-lock-type-face)
            (cond ((equal type "body") (concat " " name))
                  ((equal type "bundle")
                   (if (member name '("edit_line" "edit_xml"))
                       (concat " " name)
                     " agent"))
                  ((and range (not (string-empty-p range)))
                   (format " (%s)" range)))
            (unless (equal status "normal") (format " [%s]" status)))))

(defun cfengine-ts-mode--eldoc-attribute (&rest _)
  "Describe the attribute at point, or the one whose value point is in.
For `eldoc-documentation-functions'."
  (when-let* ((context (and (not (nth 4 (syntax-ppss)))
                            (cfengine-ts-mode--context)))
              (name (or (plist-get context :attribute)
                        (and (not (plist-get context :string))
                             (save-excursion
                               (skip-syntax-backward "w_")
                               (when (looking-at
                                      "\\([[:alnum:]_]+\\)[ \t]*=>")
                                 (match-string-no-properties 1))))))
              (entry (cfengine-ts-mode--attribute context name))
              ;; Nothing is known about a custom promise type's own.
              ((not (equal (cdr (assq 'type entry)) "custom"))))
    (cfengine-ts-mode--describe-attribute name entry)))

;;; Cross references

(defun cfengine-ts-mode--xref-backend ()
  "Return the xref backend for `cfengine-ts-mode'."
  'cfengine-ts)

(defun cfengine-ts-mode--xref-location (source line column)
  "Return an xref location for LINE and COLUMN in SOURCE.
SOURCE is a buffer or a file name."
  (if (bufferp source)
      (with-current-buffer source
        (save-excursion
          (save-restriction
            (widen)
            (goto-char (point-min))
            (forward-line (1- line))
            (move-to-column column)
            (xref-make-buffer-location source (point)))))
    (xref-make-file-location source line column)))

(cl-defmethod xref-backend-identifier-at-point ((_backend (eql cfengine-ts)))
  "Return the variable reference or the name at point, if any.
A variable reference in $(...) or ${...} carries the name of the block
it is in as the property `cfengine-ts-mode-block'."
  (if-let* ((bounds (cfengine-ts-mode--reference-bounds))
            ((< (car bounds) (cadr bounds))))
      (propertize (buffer-substring-no-properties (car bounds) (cadr bounds))
                  'cfengine-ts-mode-block
                  (plist-get (cfengine-ts-mode--context) :name))
    (save-excursion
      (skip-syntax-backward "w_")
      (and (looking-at "[[:alnum:]_]+")
           (match-string-no-properties 0)))))

(cl-defmethod xref-backend-identifier-completion-table
  ((_backend (eql cfengine-ts)))
  "Return the names of the blocks, classes and variables in the policy.
Variables are named BUNDLE.NAME."
  (seq-uniq (mapcan (lambda (d)
                      (pcase (car d)
                        ("vars" (list (concat (nth 1 d) "." (nth 2 d))))
                        ("parameter" nil)
                        (_ (list (nth 2 d)))))
                    (cfengine-ts-mode--definitions))))

(defun cfengine-ts-mode--variable-definitions (identifier block)
  "Return the definitions of variable IDENTIFIER, used in BLOCK.
IDENTIFIER is NAME or BUNDLE.NAME, optionally with a namespace prefix.
An unqualified name is looked up in BLOCK, then in every bundle."
  (let* ((reference (replace-regexp-in-string "\\`[[:alnum:]_]+:" "" identifier))
         (dot (string-search "." reference))
         (scope (if dot (substring reference 0 dot) block))
         (name (if dot (substring reference (1+ dot)) reference))
         (definitions (cfengine-ts-mode--definitions))
         (variable-p (lambda (d) (and (member (car d) '("vars" "parameter"))
                                      (equal (nth 2 d) name)))))
    (or (seq-filter (lambda (d) (and (funcall variable-p d) (equal (nth 1 d) scope)))
                    definitions)
        (unless dot
          (seq-filter (lambda (d) (and (funcall variable-p d) (equal (car d) "vars")))
                      definitions)))))

(cl-defmethod xref-backend-definitions ((_backend (eql cfengine-ts)) identifier)
  "Return the definitions of IDENTIFIER in the policy.
A variable reference is looked up among variables and parameters, and
so is a name with a dot; any other name among blocks and classes."
  (let ((block (get-text-property 0 'cfengine-ts-mode-block identifier)))
    (mapcar (lambda (d)
              (pcase-let ((`(,kind ,type ,name ,line ,column ,source) d))
                (xref-make (if (member kind '("bundle" "body" "promise"))
                               (format "%s %s %s" kind type name)
                             (format "%s %s.%s" kind type name))
                           (cfengine-ts-mode--xref-location source line column))))
            (if (or block (string-search "." identifier))
                (cfengine-ts-mode--variable-definitions identifier block)
              (seq-filter (lambda (d)
                            (and (member (car d) '("bundle" "body" "promise" "classes"))
                                 (equal (nth 2 d) identifier)))
                          (cfengine-ts-mode--definitions))))))

(cl-defmethod xref-backend-references ((_backend (eql cfengine-ts)) identifier)
  "Return the uses of IDENTIFIER in the policy, outside comments.
Uses in strings count, as in usebundle => \"name\".  For a variable,
the uses of its name, qualified or not."
  (let* ((identifier (replace-regexp-in-string "\\`.*[.:]" "" identifier))
         (regexp (concat "\\_<" (regexp-quote identifier) "\\_>"))
         matches)
    (dolist (source (cfengine-ts-mode--policy-sources))
      (with-temp-buffer
        (if (bufferp source)
            (insert-buffer-substring-no-properties
             source
             (with-current-buffer source (point-min))
             (with-current-buffer source (point-max)))
          (ignore-error file-missing (insert-file-contents source)))
        (set-syntax-table cfengine-ts-mode-syntax-table)
        (goto-char (point-min))
        (while (re-search-forward regexp nil t)
          (unless (nth 4 (save-excursion (syntax-ppss (match-beginning 0))))
            (let ((line (line-number-at-pos (match-beginning 0)))
                  (column (save-excursion (goto-char (match-beginning 0))
                                          (current-column))))
              (push (xref-make-match
                     (buffer-substring (line-beginning-position)
                                       (line-end-position))
                     (cfengine-ts-mode--xref-location source line column)
                     (length identifier))
                    matches))))))
    (nreverse matches)))

;;; Reference documentation

(defcustom cfengine-ts-mode-docs-version "lts"
  "Version of the CFEngine documentation to open.
\"lts\", \"master\", or a published version such as \"3.24\"."
  :type 'string
  :safe #'stringp)

(defconst cfengine-ts-mode--control-body-pages
  '(("agent" . "components/cf-agent/")
    ("server" . "components/cf-serverd/")
    ("executor" . "components/cf-execd/")
    ("monitor" . "components/cf-monitord/")
    ("runagent" . "components/cf-runagent/")
    ("hub" . "components/cf-hub/")
    ("common" . "components/")
    ("file" . "components/"))
  "Reference pages documenting the attributes of control bodies.")

(defun cfengine-ts-mode--attribute-page (context name)
  "Return the reference page, relative, that documents attribute NAME.
CONTEXT is from `cfengine-ts-mode--context'.  Attributes allowed in
every promise type are documented on the promise types page; a body's
attributes on the page of the promise type that uses the body, or of the
component for control bodies.  Custom promise types are documented on
one page."
  (pcase (plist-get context :block)
    (`("bundle" ,_)
     (when-let* ((section (plist-get context :section))
                 (entry (cfengine-ts-mode--attribute context name)))
       (cond ((equal (cdr (assq 'visibility entry)) "global") "promise-types/")
             ((cfengine-ts-mode--syntax 'promiseTypes section)
              (format "promise-types/%s/" section))
             (t "promise-types/custom/"))))
    (`("promise" ,_) "promise-types/custom/")
    (`("body" ,type)
     (or (cdr (assoc type cfengine-ts-mode--control-body-pages))
         (catch 'page
           (dolist (promise-type (cfengine-ts-mode--syntax 'promiseTypes))
             (when-let* ((entry (cdr (assq (intern type)
                                           (cdr (assq 'attributes
                                                      (cdr promise-type)))))))
               (when (equal (cdr (assq 'type entry)) "body")
                 (throw 'page
                        (if (equal (cdr (assq 'visibility entry)) "global")
                            "promise-types/"
                          (format "promise-types/%s/" (car promise-type))))))))))))

(defun cfengine-ts-mode--anchor (page name)
  "Return PAGE with the anchor of attribute NAME.
The custom promise types page has no anchors for attributes."
  (if (equal page "promise-types/custom/") page (concat page "#" name)))

(defun cfengine-ts-mode-docs-url ()
  "Return the reference documentation URL for the thing at point.
That is the function, attribute or promise type at point, or the
attribute whose value point is in; otherwise the reference index."
  (let* ((context (cfengine-ts-mode--context))
         (word (save-excursion
                 (skip-syntax-backward "w_")
                 (and (looking-at "[[:alnum:]_]+")
                      (match-string-no-properties 0))))
         (after (save-excursion (skip-syntax-forward "w_")
                                (skip-chars-forward " \t")
                                (char-after)))
         (page
          (cond
           ((and word (eq after ?\()
                 (assq (intern word) (cfengine-ts-mode--syntax 'functions)))
            (format "functions/%s/" word))
           ((and word context (not (plist-get context :string))
                 (save-excursion (skip-syntax-forward "w_")
                                 (looking-at-p "[ \t]*=>")))
            (when-let* ((base (cfengine-ts-mode--attribute-page context word)))
              (cfengine-ts-mode--anchor base word)))
           ((and word (eq after ?:)
                 (assq (intern word) (cfengine-ts-mode--syntax 'promiseTypes)))
            (format "promise-types/%s/" word))
           ((and word (eq after ?:)
                 (equal (car (plist-get context :block)) "bundle")
                 (member word (cfengine-ts-mode--custom-promise-types
                               (nth 1 (plist-get context :block)))))
            "promise-types/custom/")
           ((plist-get context :attribute)
            (let ((name (plist-get context :attribute)))
              (when-let* ((base (cfengine-ts-mode--attribute-page context name)))
                (cfengine-ts-mode--anchor base name)))))))
    (format "https://docs.cfengine.com/docs/%s/reference/%s"
            cfengine-ts-mode-docs-version (or page ""))))

(defun cfengine-ts-mode-browse-docs ()
  "Open the reference documentation for the thing at point.
See `cfengine-ts-mode-docs-url' and `cfengine-ts-mode-docs-version'."
  (interactive)
  (browse-url (cfengine-ts-mode-docs-url)))

(defvar-keymap cfengine-ts-mode-map
  :doc "Keymap for `cfengine-ts-mode'."
  "C-c C-f" #'cfengine-ts-mode-format-buffer
  "C-c C-r" #'cfengine-ts-mode-format-region
  "C-c C-j" #'cfengine3-reformat-json-string
  "C-c C-d" #'cfengine-ts-mode-browse-docs)

;;;###autoload
(define-derived-mode cfengine-ts-mode prog-mode "CFEngine3[ts]"
  "Major mode for CFEngine 3 policy, powered by tree-sitter."
  :syntax-table cfengine-ts-mode-syntax-table
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
  (add-hook 'eldoc-documentation-functions
            #'cfengine-ts-mode--eldoc-attribute nil t)
  ;; Each added function runs before those added earlier: variables,
  ;; then the syntax, classes, and function names last.
  (add-hook 'completion-at-point-functions
            #'cfengine-ts-mode--completion-at-point nil t)
  (add-hook 'completion-at-point-functions
            #'cfengine-ts-mode--class-completion-at-point nil t)
  (add-hook 'completion-at-point-functions
            #'cfengine-ts-mode--syntax-completion-at-point nil t)
  (add-hook 'completion-at-point-functions
            #'cfengine-ts-mode--variable-completion-at-point nil t)
  (add-hook 'xref-backend-functions #'cfengine-ts-mode--xref-backend nil t)
  (add-hook 'flymake-diagnostic-functions #'cfengine-ts-mode-flymake nil t)
  (when (featurep 'flycheck)
    (cfengine-ts-mode-flycheck-setup))
  (add-hook 'before-save-hook #'cfengine-ts-mode--format-before-save nil t)
  ;; Reindent as section headers, class guards and statements are typed.
  (setq-local electric-indent-chars
              (append '(?: ?\; ?\}) electric-indent-chars))
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
    ;; Fold blocks, then the sections inside bundles.
    (setq-local treesit-outline-predicate
                (rx bos (or "bundle_block" "body_block" "promise_block"
                            "bundle_section")
                    eos))
    ;; M-a and M-e move by promise, and by attribute in bodies.
    (setq-local treesit-thing-settings
                `((cfengine
                   (sentence (or ,(rx bos (or "promise" "half_promise") eos)
                                 cfengine-ts-mode--body-attribute-p)))))
    (treesit-major-mode-setup)
    (setq-local forward-sentence-function #'cfengine-ts-mode--forward-sentence)
    (setq-local indent-line-function #'cfengine-ts-mode--indent-line)))

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
