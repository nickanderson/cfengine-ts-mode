EMACS ?= emacs
# Directory holding libtree-sitter-cfengine.so.  `make grammar' builds it here.
TREESIT_DIR ?= $(CURDIR)/.treesit

BATCH = $(EMACS) -Q --batch -L . -L test --eval "(setq load-prefer-newer t)" \
	--eval '(add-to-list (quote treesit-extra-load-path) "$(TREESIT_DIR)")'

.PHONY: all compile checkdoc test grammar clean

all: compile checkdoc test

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile cfengine-ts-mode.el

checkdoc:
	$(BATCH) --eval '(checkdoc-file "cfengine-ts-mode.el")'

test:
	$(BATCH) -l test/cfengine-ts-mode-tests.el -f ert-run-tests-batch-and-exit

grammar:
	$(BATCH) -l cfengine-ts-mode.el \
	  --eval '(treesit-install-language-grammar (quote cfengine) "$(TREESIT_DIR)")'

clean:
	rm -f *.elc test/*.elc
