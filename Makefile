AGENTICA ?= agentica
# A path is made absolute: the recipes run it from the package folders.
override AGENTICA := $(if $(findstring /,$(AGENTICA)),$(abspath $(AGENTICA)),$(AGENTICA))
# The tests of the clients start the client with the same binary.
export AGENTICA

# The members of the workspace (agentica.toml): one folder per package, each with its own agentica.toml.
PACKAGES = sse llm mcp protocol monty bash client core cli tui_client examples/extension
# How many files, packages or checks run at once.
JOBS ?= 4
# Packages that never depend on the server or a client, so they can move to a repo of their own.
LEAVES = llm mcp sse protocol monty bash
SERVER_AND_CLIENTS = core|client|cli|tui_client|web_client
# A client, and `client` (the code every client shares), reach the server only through the protocol: they never
# depend on these (or on another client).
NOT_FOR_CLIENTS = core|llm|mcp|monty|cli|tui_client|web_client

# A fake key in the environment of every recipe: the bash test of core checks that the tool does not pass it on.
export AGC_TEST_SECRET = sk-test-secret-must-not-reach-bash

# $(call none,DESCRIPTION,RG ARGS): fails when rg finds a match or cannot search (rg: 0 found, 1 none, 2 error).
none = rg -n $(2); case $$? in 1) ;; 0) echo "coupling: $(1)" >&2; exit 1 ;; *) exit 2 ;; esac

# $(call core_imports,FOLDER,ALLOWED): the rg arguments that find an import of core/src/FOLDER from another core folder
# than those of ALLOWED (a|b), or with a `..` after its first folder. Needs rg with PCRE2; without it rg fails, and so
# does the rule.
core_imports = -P -g 'core/src/$(1)/**' '^import \w+ from "\.\./((?!($(2))/)|[^"]*/\.\.(/|"))' .

# The llama-server of `smoke-llama`, fetched by scripts/ into .tools/ (gitignored). LLAMA_URL uses a running one.
LLAMA_SERVER ?= $(CURDIR)/.tools/llama.cpp/llama-server
LLAMA_MODEL ?= $(CURDIR)/.tools/models/qwen2.5-0.5b-instruct-q4_k_m.gguf
# The model of `live-fireworks`.
FIREWORKS_MODEL ?= accounts/fireworks/models/deepseek-v4p1-flash-1017

# $(call tests,PACKAGE,FOLDER[,JOBS]): runs the .agc tests of FOLDER, JOBS files at a time (one for the tests that share
# a real server or cost money); a run that passes no test fails, so tests that are no
# longer found never pass in silence.
tests = out=$$(cd $(1) && $(AGENTICA) test --jobs $(or $(3),$(JOBS)) $(2)); status=$$?; echo "$$out"; [ $$status -eq 0 ] || exit 1; \
  echo "$$out" | tail -n 1 | grep -Eq '^[1-9][0-9]* passed' || { echo "no test passed in $(1)/$(2)" >&2; exit 1; }

.PHONY: install check coupling fmt-check native-gen native-header native-check unit unit-package smoke pty peer test smoke-llama smoke-monty live-fireworks smoke-anthropic live-anthropic-core

# The packages from outside this repository (bond, agentica-tui) go into the package's deps/ (gitignored).
install:
	cd core && $(AGENTICA) install
	cd tui_client && $(AGENTICA) install
	cd examples/extension && $(AGENTICA) install

# Each file of a package is checked by itself (that is what `check .` does, one after the other), JOBS at a time.
check: coupling install
	for pkg in $(PACKAGES); do \
	  (cd $$pkg && find . -name '*.agc' -not -path './deps/*' -not -path './_build/*' | sort \
	    | xargs -P $(JOBS) -n 2 $(AGENTICA) check) || exit 1; \
	done

coupling:
	@$(call none,$(LEAVES) depend on the server or a client,$(foreach p,$(LEAVES),-g '$(p)/**') \
	  -e 'subdir *= *"($(SERVER_AND_CLIENTS))"' -e '"pkg/($(SERVER_AND_CLIENTS))/' .)
	@$(call none,a client depends on the server or the llm or another client,-g 'client/**' -g 'cli/**' -g 'tui_client/**' \
	  -e 'subdir *= *"($(NOT_FOR_CLIENTS))"' -e '"pkg/($(NOT_FOR_CLIENTS))/' .)
	@$(call none,a package imports another package's src/ (use its public module),-g '*.agc' 'pkg/[a-z0-9_-]+/src/' .)
	@$(call none,core/src/tools imports another core folder,$(call core_imports,tools,tools))
	@$(call none,core/src/approval imports a core folder but tools,$(call core_imports,approval,tools))
	@$(call none,core/src/ext imports a core folder but tools,$(call core_imports,ext,tools))
	@$(call none,core/src/providers imports another core folder,$(call core_imports,providers,providers))
	@$(call none,core/src/agent imports a core folder but tools approval and providers,$(call core_imports,agent,tools|approval|providers))
	@$(call none,core/src/session imports http,$(call core_imports,session,agent|tools|ext|approval|config|providers))
	@$(call none,a session file outside the actor imports one of its parts,-g 'core/src/session/**' \
	  $(foreach f,actor turn stream branch state,-g '!core/src/session/$(f).agc') '^import \w+ from "(turn|stream|branch|state)"' .)
	@$(call none,a session file but storage.agc reaches the session files (prompt.agc and folder.agc read the session's working folder),-g 'core/src/session/**' \
	  $(foreach f,storage prompt folder,-g '!core/src/session/$(f).agc') '\b(File|Dir)\.|Path\.(remove|rename)\b' .)
	@$(call none,core/src/config imports a core folder but tools approval and providers,$(call core_imports,config,tools|approval|providers))
	@$(call none,core/src/http imports a core folder but session config and providers,$(call core_imports,http,session|config|providers))
	@$(call none,core/src/http imports a file of session but session.agc,-g 'core/src/http/**' '^import \w+ from "\.\./session/(?!session")' -P .)

# The header of bash's native module, made by native-gen from the extern block (bash/src/tree.agc); native-check fails
# when the committed one is stale. The clone is made again when it is not NATIVE_GEN_COMMIT or has no cli.agc (a clone
# that stopped midway).
NATIVE_GEN = .tools/native-gen-0.4.0
NATIVE_GEN_COMMIT = 42a1fd2b39a08bc1524aa9c5a2d2525f0f29aba0
native-gen:
	@if [ ! -f '$(NATIVE_GEN)/native-gen/cli.agc' ] || \
	  [ "$$(git -C '$(NATIVE_GEN)' rev-parse HEAD 2>/dev/null)" != $(NATIVE_GEN_COMMIT) ]; then \
	  rm -rf '$(NATIVE_GEN)' && \
	  git clone -q --depth 1 --branch native-gen-0.4.0 https://github.com/agentica-lang/packages '$(NATIVE_GEN)' && \
	  [ "$$(git -C '$(NATIVE_GEN)' rev-parse HEAD)" = $(NATIVE_GEN_COMMIT) ] || \
	  { echo 'native-gen: the tag native-gen-0.4.0 is not $(NATIVE_GEN_COMMIT)' >&2; exit 1; }; \
	fi
native-header: native-gen
	cd bash && $(AGENTICA) ../$(NATIVE_GEN)/native-gen/cli.agc src/tree.agc --output native/bash_native.h
native-check: native-gen
	cd bash && $(AGENTICA) ../$(NATIVE_GEN)/native-gen/cli.agc src/tree.agc --output native/bash_native.h --check

fmt-check:
	printf '%s\n' $(PACKAGES) | xargs -P $(JOBS) -I{} sh -c 'cd {} && $(AGENTICA) fmt --check .'

# The packages run at once, and the files of each (`agentica test --jobs`).
unit:
	printf '%s\n' $(PACKAGES) | xargs -P $(JOBS) -I{} $(MAKE) --no-print-directory unit-package PACKAGE={}

# The packages without tests of their own: core's tests run the example extension.
NO_TESTS = examples/extension

# The cli tests run the client and the fake server from bytecode compiled once, not from source in every process; the
# core tests run the example extension so too.
unit-package:
	@if [ -n "$(filter $(PACKAGE),$(NO_TESTS))" ]; then echo "$(PACKAGE): no tests (NO_TESTS)"; exit 0; fi; \
	if [ "$(PACKAGE)" = core ]; then mkdir -p core/_build/bin && \
	  $(AGENTICA) compile examples/extension/main.agc -o core/_build/bin/extension.agcb >/dev/null && \
	  export EXTENSION_BYTECODE='$(CURDIR)/core/_build/bin/extension.agcb'; fi; \
	if [ "$(PACKAGE)" = cli ]; then mkdir -p cli/_build/bin && \
	  $(AGENTICA) compile cli/main.agc -o cli/_build/bin/cli.agcb >/dev/null && \
	  $(AGENTICA) compile cli/tests/support/fake_main.agc -o cli/_build/bin/fake.agcb >/dev/null && \
	  $(AGENTICA) compile core/main.agc -o cli/_build/bin/core.agcb >/dev/null; fi; \
	if [ "$(PACKAGE)" = cli ]; then export CLI_BYTECODE='$(CURDIR)/cli/_build/bin/cli.agcb' \
	  FAKE_BYTECODE='$(CURDIR)/cli/_build/bin/fake.agcb' CORE_BYTECODE='$(CURDIR)/cli/_build/bin/core.agcb'; fi; \
	$(call tests,$(PACKAGE),tests)

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
	out=$$('$(CURDIR)/bin/finn' tui --version) && echo "$$out" | grep -qx 'Finn Agent tui [0-9.]*'

# The TUI client under a pseudo-terminal, against the server against a fake model (Python, standard library only). The
# client and the core are compiled once, and the tests run JOBS at a time, one process each.
pty: install
	JOBS=$(JOBS) python3 tui_client/tests/run_pty.py

# The commands bash's parser finds against those real bash runs (Python standard library only).
peer:
	python3 -m unittest bash/tests/test_bash_peer.py -v

test: check native-check unit smoke pty peer

# The llm tests against a real llama-server with Qwen2.5-0.5B (fetched and checked by sha256 first), or the one at
# LLAMA_URL. Local only, never in CI.
smoke-llama:
	@if [ -n "$$CI" ]; then echo "smoke-llama: refused in CI" >&2; exit 1; fi
	if [ -z "$$LLAMA_URL" ]; then scripts/fetch-llama.sh && scripts/fetch-model.sh; fi
	mkdir -p llm/_build/llama-logs
	export LLAMA_SERVER='$(LLAMA_SERVER)' LLAMA_MODEL='$(LLAMA_MODEL)' LLAMA_LOG_DIR='$(CURDIR)/llm/_build/llama-logs'; \
	$(call tests,llm,smoke,1)

# The monty tests against the real worker: the pinned wheel of this platform, fetched from PyPI into .tools/cache with
# its sha256 checked, or the binary at MONTY_BIN.
smoke-monty:
	$(call tests,monty,real,1)

# A real Fireworks call, which costs money: local only, with the owner's yes, never in CI. Skips without the key.
live-fireworks:
	@if [ -n "$$CI" ]; then echo "live-fireworks: refused in CI" >&2; exit 1; fi; \
	if [ -z "$$FIREWORKS_API_KEY" ]; then echo "live-fireworks: FIREWORKS_API_KEY is unset, skipped"; exit 0; fi; \
	export FIREWORKS_MODEL='$(FIREWORKS_MODEL)'; $(call tests,llm,live/fireworks_test.agc,1)

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
	rm -f "$$ANTHROPIC_LIVE_REPORT"; $(call tests,llm,live/anthropic_test.agc,1); cat "$$ANTHROPIC_LIVE_REPORT"

# A real core session on Anthropic's cheap model (three calls: a tool round, then a second turn that must read the
# cache), which costs money: local only, with the owner's yes, never in CI. The credential as for smoke-anthropic.
live-anthropic-core:
	@if [ -n "$$CI" ]; then echo "live-anthropic-core: refused in CI" >&2; exit 1; fi; \
	if [ -z "$$ANTHROPIC_API_KEY$$ANTHROPIC_AUTH_TOKEN" ]; then \
	  if ! command -v ant >/dev/null; then echo "live-anthropic-core: no key, no token and no ant, skipped"; exit 0; fi; \
	  ANTHROPIC_AUTH_TOKEN=$$(ant auth print-credentials --access-token 2>/dev/null) || ANTHROPIC_AUTH_TOKEN=; \
	  if [ -z "$$ANTHROPIC_AUTH_TOKEN" ]; then echo "live-anthropic-core: ant is not logged in, skipped"; exit 0; fi; \
	  export ANTHROPIC_AUTH_TOKEN; \
	fi; \
	mkdir -p core/_build; export ANTHROPIC_LIVE_REPORT='$(CURDIR)/core/_build/anthropic-live.txt'; \
	rm -f "$$ANTHROPIC_LIVE_REPORT"; $(call tests,core,live/anthropic_test.agc,1); cat "$$ANTHROPIC_LIVE_REPORT"

# The user guide (docs/, Hugo with the docs theme, a submodule): Hugo 0.167 or later, Dart Sass on PATH (or in
# DART_SASS) and Node for the highlighter of the agentica blocks. A Hugo warning fails it, a broken page link too.
DOCS_THEME := docs/themes/docs-theme
DART_SASS ?= $(HOME)/.local/opt/dart-sass

.PHONY: docs docs-serve

$(DOCS_THEME)/highlight/node_modules: $(DOCS_THEME)/highlight/package.json $(DOCS_THEME)/highlight/package-lock.json
	npm ci --prefix $(DOCS_THEME)/highlight --ignore-scripts --no-audit --no-fund
	touch $@

docs docs-serve: export PATH := $(DART_SASS):$(PATH)

docs: $(DOCS_THEME)/highlight/node_modules
	@test -e $(DOCS_THEME)/hugo.toml || { echo "docs needs its theme: git submodule update --init $(DOCS_THEME)" >&2; exit 1; }
	hugo --cleanDestinationDir --source docs --panicOnWarning $(HUGO_FLAGS)
	@# The highlighter fails on a site with no agentica block.
	if grep -rqE 'class="?agc-code' docs/public; then node $(DOCS_THEME)/highlight/highlight.mjs docs/public; fi

docs-serve:
	hugo server --source docs
