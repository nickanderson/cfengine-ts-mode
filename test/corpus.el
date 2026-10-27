;;; corpus.el --- Indentation round-trip over a directory of policy -*- lexical-binding: t; -*-

;;; Commentary:

;; Usage: emacs --batch -l corpus.el DIR
;;
;; Every .cf file in DIR must already be formatted by `cfengine format'.
;; Each is stripped of indentation and reindented; files that come back
;; different are reported with their first differing line, and the exit
;; status is non-zero.

;;; Code:

(require 'cfengine-ts-mode)

(let ((dir (car command-line-args-left))
      (ok 0) (bad 0))
  (dolist (file (directory-files dir t "\\.cf\\'"))
    (with-temp-buffer
      (insert-file-contents file)
      (cfengine-ts-mode)
      (let ((expected (buffer-string)))
        (goto-char (point-min))
        (while (not (eobp))
          (unless (nth 3 (syntax-ppss))
            (delete-horizontal-space t))
          (forward-line 1))
        (indent-region (point-min) (point-max))
        (if (equal expected (buffer-string))
            (setq ok (1+ ok))
          (setq bad (1+ bad))
          (let ((want (split-string expected "\n"))
                (got (split-string (buffer-string) "\n"))
                (line 1))
            (while (equal (car want) (car got))
              (setq want (cdr want) got (cdr got) line (1+ line)))
            (message "%s:%d\n  want: %S\n   got: %S"
                     (file-name-nondirectory file) line (car want) (car got)))))))
  (message "%d of %d files reindent unchanged" ok (+ ok bad))
  (kill-emacs (if (zerop bad) 0 1)))

;;; corpus.el ends here
