
EMACS=emacs
DIFF=diff

test: sm-c-mode-test.c.test

.PHONY: refresh
refresh:

%.elc : %.el
	$(EMACS) --batch -L . --no-init-file -f batch-byte-compile $<

%.test: % sm-c-mode.elc refresh
	$(EMACS) --batch -l sm-c-mode-autoloads.el 		 \
	    sm-c-mode-test.c 					 \
	    --eval '(setq indent-tabs-mode nil)'                 \
	    --eval '(setq create-lockfiles nil)' 		 \
	    --eval '(indent-region (point-min) (point-max) nil)' \
	    --eval '(indent-region (point-min) (point-max) nil)' \
	    --eval '(write-region (point-min) (point-max) "$@")'
	$(DIFF) $< $@ || true; $(RM) $@
