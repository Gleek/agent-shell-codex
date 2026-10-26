EMACS ?= emacs
AGENT_SHELL_DIR ?= ../agent-shell
SHELL_MAKER_DIR ?= ../shell-maker
ACP_DIR ?= ../acp
EXTRA_LOAD_PATH ?=
LOAD_PATH = -L $(AGENT_SHELL_DIR) -L $(SHELL_MAKER_DIR) -L $(ACP_DIR) -L . $(EXTRA_LOAD_PATH)

.PHONY: test compile

test:
	$(EMACS) -Q --batch $(LOAD_PATH) -l agent-shell-codex.el -l tests/agent-shell-codex-tests.el -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile agent-shell-codex.el
