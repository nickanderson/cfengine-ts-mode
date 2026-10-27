EMACS ?= emacs
# Directory holding libtree-sitter-cfengine.so.  `make grammar' builds it here.
TREESIT_DIR ?= $(CURDIR)/.treesit

BATCH = $(EMACS) -Q --batch -L . -L test --eval "(setq load-prefer-newer t)" \
	--eval '(add-to-list (quote treesit-extra-load-path) "$(TREESIT_DIR)")'

.PHONY: all compile checkdoc test corpus grammar clean

all: compile checkdoc test

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile cfengine-ts-mode.el

checkdoc:
	$(BATCH) --eval '(checkdoc-file "cfengine-ts-mode.el")' \
	  --eval '(when (get-buffer "*Warnings*") (kill-emacs 1))'

test:
	$(BATCH) -l test/cfengine-ts-mode-tests.el -f ert-run-tests-batch-and-exit

# Reindent every policy file in a masterfiles checkout, formatted first by
# `cfengine format', and compare.  Templates (.cf.in) are skipped.
corpus:
	@test -n "$(MASTERFILES)" || \
	  { echo "usage: make corpus MASTERFILES=/path/to/masterfiles"; exit 1; }
	rm -rf .corpus && mkdir .corpus
	cd "$(MASTERFILES)" && git ls-files '*.cf' | grep -v '^tests/' | \
	  while read -r f; do cp "$$f" "$(CURDIR)/.corpus/$$(echo "$$f" | tr / _)"; done
	cfengine format .corpus/*.cf > /dev/null
	$(BATCH) -l test/corpus.el .corpus

grammar:
	$(BATCH) -l cfengine-ts-mode.el \
	  --eval '(treesit-install-language-grammar (quote cfengine) "$(TREESIT_DIR)")'

clean:
	rm -rf *.elc test/*.elc .corpus
