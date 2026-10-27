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
;; content: a `.cf' or `.cf.sub' file with a bundle, body or promise
;; block opens in `cfengine3-mode', or in this mode once the grammar is
;; installed.
;;
;; Function completion and ElDoc signatures come from `cfengine.el'.
;; They use the syntax of the installed `cf-promises' (see
;; `cfengine-cf-promises'), or built-in data when it isn't found.

;;; Code:

(require 'treesit)
(require 'cfengine)

(defgroup cfengine-ts nil
  "Tree-sitter support for CFEngine 3 policy."
  :group 'cfengine)

(defcustom cfengine-ts-mode-indent-offset 2
  "Number of spaces for each indentation level in `cfengine-ts-mode'."
  :type 'integer
  :safe #'integerp)

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
The file name must end in .cf or .cf.sub and the text must contain a
bundle, body or promise block.  Intended for `magic-mode-alist'."
    (and buffer-file-name
         (string-match-p "\\.cf\\(?:\\.sub\\)?\\'" buffer-file-name)
         (re-search-forward
          "^[ \t]*\\(?:bundle\\|body\\|promise\\)[ \t]+[[:alnum:]_]+[ \t]+[[:alnum:]_.:]+"
          nil t))))

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

(defvar cfengine-ts-mode--indent-rules
  ;; Node-type matchers are regexps, so anchor them: "promise" would
  ;; otherwise also match "class_guarded_promises".
  `((cfengine
     (cfengine-ts-mode--inside-string-p cfengine-ts-mode--bol 0)
     ((node-is ,(rx bos "macro" eos)) column-0 0)
     ((parent-is ,(rx bos "source_file" eos)) column-0 0)
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
