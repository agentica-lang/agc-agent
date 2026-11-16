AGENTICA ?= agentica
# A path is made absolute: the recipes run it from the package folders.
override AGENTICA := $(if $(findstring /,$(AGENTICA)),$(abspath $(AGENTICA)),$(AGENTICA))
# The tests of the clients start the client with the same binary.
export AGENTICA

# The members of the workspace (agentica.toml): one folder per package, each with its own agentica.toml.
PACKAGES = sse llm mcp protocol monty shell client core cli tui_client
# Packages that never depend on the server or a client, so they can move to a repo of their own.
LEAVES = llm mcp sse protocol monty shell
SERVER_AND_CLIENTS = core|client|cli|tui_client|web_client
# A client, and `client` (the code every client shares), reach the server only through the protocol: they never
# depend on these (or on another client).
NOT_FOR_CLIENTS = core|llm|mcp|monty|shell|cli|tui_client|web_client

# A fake key in the environment of every recipe: the bash test of core checks that the tool does not pass it on.
export AGC_TEST_SECRET = sk-test-secret-must-not-reach-bash

# $(call none,DESCRIPTION,RG ARGS): fails when rg finds a match or cannot search (rg: 0 found, 1 none, 2 error).
none = rg -n $(2); case $$? in 1) ;; 0) echo "coupling: $(1)" >&2; exit 1 ;; *) exit 2 ;; esac

# The llama-server of `smoke-llama`, fetched by scripts/ into .tools/ (gitignored). LLAMA_URL uses a running one.
LLAMA_SERVER ?= $(CURDIR)/.tools/llama.cpp/llama-server
LLAMA_MODEL ?= $(CURDIR)/.tools/models/qwen2.5-0.5b-instruct-q4_k_m.gguf
# The model of `live-fireworks`.
FIREWORKS_MODEL ?= accounts/fireworks/models/deepseek-v4p1-flash-1017

# $(call tests,PACKAGE,FOLDER): runs the .agc tests of FOLDER; a run that passes no test fails, so tests that are no
# longer found never pass in silence.
tests = out=$$(cd $(1) && $(AGENTICA) test $(2)); status=$$?; echo "$$out"; [ $$status -eq 0 ] || exit 1; \
  echo "$$out" | tail -n 1 | grep -Eq '^[1-9][0-9]* passed' || { echo "no test passed in $(1)/$(2)" >&2; exit 1; }

.PHONY: install check coupling fmt-check unit smoke pty peer test smoke-llama smoke-monty live-fireworks smoke-anthropic

# The packages from outside this repository (agentica-tui) go into the package's deps/ (gitignored).
install:
	cd tui_client && $(AGENTICA) install

check: coupling install
	for pkg in $(PACKAGES); do (cd $$pkg && $(AGENTICA) check .) || exit 1; done

coupling:
	@$(call none,$(LEAVES) depend on the server or a client,$(foreach p,$(LEAVES),-g '$(p)/**') \
	  -e 'subdir *= *"($(SERVER_AND_CLIENTS))"' -e '"pkg/($(SERVER_AND_CLIENTS))/' .)
	@$(call none,a client depends on the server or the llm or another client,-g 'client/**' -g 'cli/**' -g 'tui_client/**' \
	  -e 'subdir *= *"($(NOT_FOR_CLIENTS))"' -e '"pkg/($(NOT_FOR_CLIENTS))/' .)
	@$(call none,a package imports another package's src/ (use its public module),-g '*.agc' 'pkg/[a-z0-9_-]+/src/' .)

fmt-check:
	for pkg in $(PACKAGES); do (cd $$pkg && $(AGENTICA) fmt --check .) || exit 1; done

unit:
	for pkg in $(PACKAGES); do $(call tests,$$pkg,tests); done

# The entry points run, with their packages read from the workspace; bin/finn also from another folder, through a
# relative symlink to the bin folder and one to the script (in .tools/, gitignored).
smoke: install
	out=$$($(AGENTICA) core/main.agc --version) && echo "$$out" | grep -qx 'Finn Agent core [0-9.]* (llm [0-9.]*)'
	out=$$($(AGENTICA) cli/main.agc --version) && echo "$$out" | grep -qx 'Finn Agent cli [0-9.]*'
	mkdir -p .tools/smoke && ln -sfn ../../bin .tools/smoke/bin && ln -sf '$(CURDIR)/bin/finn' .tools/smoke/finn
	cd / && finn='$(CURDIR)/.tools/smoke/bin/finn' && out=$$("$$finn" --version) && \
	  echo "$$out" | grep -qx 'Finn Agent core [0-9.]* (llm [0-9.]*)' && echo "$$out" | grep -qx 'Finn Agent cli [0-9.]*' && \
	  "$$finn" --help | grep -q '^usage: finn' && "$$finn" serve --help | grep -q '^usage: finn serve' && \
	  "$$finn" chat --help | grep -q '^Usage: finn' && ! "$$finn" serve --bogus 2>/dev/null && \
	  '$(CURDIR)/.tools/smoke/finn' --version | grep -qx 'Finn Agent cli [0-9.]*'
	out=$$($(AGENTICA) tui_client/main.agc --version) && echo "$$out" | grep -qx 'Finn Agent tui [0-9.]*'

# The TUI client under a pseudo-terminal, against the server against a fake model (Python, standard library only).
pty: install
	python3 -m unittest tui_client/tests/test_pty.py -v

# The bash parser of `shell` against real bash (Python standard library only).
peer:
	python3 -m unittest shell/tests/test_bash_peer.py -v

test: check unit smoke pty peer

# The llm tests against a real llama-server with Qwen2.5-0.5B (fetched and checked by sha256 first), or the one at
# LLAMA_URL.
smoke-llama:
	if [ -z "$$LLAMA_URL" ]; then scripts/fetch-llama.sh && scripts/fetch-model.sh; fi
	mkdir -p llm/_build/llama-logs
	export LLAMA_SERVER='$(LLAMA_SERVER)' LLAMA_MODEL='$(LLAMA_MODEL)' LLAMA_LOG_DIR='$(CURDIR)/llm/_build/llama-logs'; \
	$(call tests,llm,smoke)

# The monty tests against the real worker: the pinned wheel of this platform, fetched from PyPI into .tools/cache with
# its sha256 checked, or the binary at MONTY_BIN.
smoke-monty:
	$(call tests,monty,real)

# A real Fireworks call, which costs money: local only, with the owner's yes, never in CI. Skips without the key.
live-fireworks:
	@if [ -n "$$CI" ]; then echo "live-fireworks: refused in CI" >&2; exit 1; fi; \
	if [ -z "$$FIREWORKS_API_KEY" ]; then echo "live-fireworks: FIREWORKS_API_KEY is unset, skipped"; exit 0; fi; \
	export FIREWORKS_MODEL='$(FIREWORKS_MODEL)'; $(call tests,llm,live/fireworks_test.agc)

# Four real calls to Anthropic's cheap model (a text turn, a tool round, a cache read), which cost money: local only,
# with the owner's yes, never in CI. Without ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN it takes the token of
# `ant auth login`, never printed; it skips when ant is missing or not logged in.
smoke-anthropic:
	@if [ -n "$$CI" ]; then echo "smoke-anthropic: refused in CI" >&2; exit 1; fi; \
	if [ -z "$$ANTHROPIC_API_KEY$$ANTHROPIC_AUTH_TOKEN" ]; then \
	  if ! command -v ant >/dev/null; then echo "smoke-anthropic: no key, no token and no ant, skipped"; exit 0; fi; \
	  ANTHROPIC_AUTH_TOKEN=$$(ant auth print-credentials --access-token 2>/dev/null) || ANTHROPIC_AUTH_TOKEN=; \
	  if [ -z "$$ANTHROPIC_AUTH_TOKEN" ]; then echo "smoke-anthropic: ant is not logged in, skipped"; exit 0; fi; \
	  export ANTHROPIC_AUTH_TOKEN; \
	fi; \
	mkdir -p llm/_build; export ANTHROPIC_LIVE_REPORT='$(CURDIR)/llm/_build/anthropic-live.txt'; \
	rm -f "$$ANTHROPIC_LIVE_REPORT"; $(call tests,llm,live/anthropic_test.agc); cat "$$ANTHROPIC_LIVE_REPORT"
