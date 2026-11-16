AGENTICA ?= agentica
# The tests of the clients start the client with the same binary.
export AGENTICA

# The members of the workspace (agentica.toml): one folder per package, each with its own agentica.toml.
PACKAGES = sse llm protocol core cli
# Packages that never depend on the server or a client, so they can move to a repo of their own.
LEAVES = llm sse protocol
SERVER_AND_CLIENTS = core|cli|tui_client|web_client
# A client reaches the server only through the protocol: it never depends on these.
NOT_FOR_CLIENTS = core|llm|tui_client|web_client

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

.PHONY: check coupling fmt-check unit smoke test smoke-llama live-fireworks

check: coupling
	for pkg in $(PACKAGES); do (cd $$pkg && $(AGENTICA) check .) || exit 1; done

coupling:
	@$(call none,$(LEAVES) depend on the server or a client,$(foreach p,$(LEAVES),-g '$(p)/**') \
	  -e 'subdir *= *"($(SERVER_AND_CLIENTS))"' -e '"pkg/($(SERVER_AND_CLIENTS))/' .)
	@$(call none,cli depends on the server or on the llm,-g 'cli/**' \
	  -e 'subdir *= *"($(NOT_FOR_CLIENTS))"' -e '"pkg/($(NOT_FOR_CLIENTS))/' .)
	@$(call none,a package imports another package's src/ (use its public module),-g '*.agc' 'pkg/[a-z0-9_-]+/src/' .)

fmt-check:
	for pkg in $(PACKAGES); do (cd $$pkg && $(AGENTICA) fmt --check .) || exit 1; done

unit:
	for pkg in $(PACKAGES); do $(call tests,$$pkg,tests); done

# The entry points run, with their packages read from the workspace; bin/agc also from another folder, through a
# relative symlink to the bin folder and one to the script (in .tools/, gitignored).
smoke:
	out=$$($(AGENTICA) core/main.agc --version) && echo "$$out" | grep -qx 'agc-agent core [0-9.]* (llm [0-9.]*)'
	out=$$($(AGENTICA) cli/main.agc --version) && echo "$$out" | grep -qx 'agc-agent cli [0-9.]*'
	mkdir -p .tools/smoke && ln -sfn ../../bin .tools/smoke/bin && ln -sf '$(CURDIR)/bin/agc' .tools/smoke/agc
	cd / && agc='$(CURDIR)/.tools/smoke/bin/agc' && out=$$("$$agc" --version) && \
	  echo "$$out" | grep -qx 'agc-agent core [0-9.]* (llm [0-9.]*)' && echo "$$out" | grep -qx 'agc-agent cli [0-9.]*' && \
	  "$$agc" --help | grep -q '^usage: agc' && "$$agc" serve --help | grep -q '^usage: agc serve' && \
	  "$$agc" chat --help | grep -q '^Usage: agc' && ! "$$agc" serve --bogus 2>/dev/null && \
	  '$(CURDIR)/.tools/smoke/agc' --version | grep -qx 'agc-agent cli [0-9.]*'

test: check unit smoke

# The llm tests against a real llama-server with Qwen2.5-0.5B (fetched and checked by sha256 first), or the one at
# LLAMA_URL.
smoke-llama:
	if [ -z "$$LLAMA_URL" ]; then scripts/fetch-llama.sh && scripts/fetch-model.sh; fi
	mkdir -p llm/_build/llama-logs
	export LLAMA_SERVER='$(LLAMA_SERVER)' LLAMA_MODEL='$(LLAMA_MODEL)' LLAMA_LOG_DIR='$(CURDIR)/llm/_build/llama-logs'; \
	$(call tests,llm,smoke)

# A real Fireworks call, which costs money: local only, with the owner's yes, never in CI. Skips without the key.
live-fireworks:
	@if [ -n "$$CI" ]; then echo "live-fireworks: refused in CI" >&2; exit 1; fi; \
	if [ -z "$$FIREWORKS_API_KEY" ]; then echo "live-fireworks: FIREWORKS_API_KEY is unset, skipped"; exit 0; fi; \
	export FIREWORKS_MODEL='$(FIREWORKS_MODEL)'; $(call tests,llm,live)
