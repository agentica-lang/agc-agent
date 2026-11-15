AGENTICA ?= agentica

# The members of the workspace (agentica.toml): one folder per package, each with its own agentica.toml.
PACKAGES = sse llm core
# Packages that never depend on the server or a client, so they can move to a repo of their own.
LEAVES = llm sse protocol
SERVER_AND_CLIENTS = core|cli|tui_client|web_client

# $(call none,DESCRIPTION,RG ARGS): fails when rg finds a match or cannot search (rg: 0 found, 1 none, 2 error).
none = rg -n $(2); case $$? in 1) ;; 0) echo "coupling: $(1)" >&2; exit 1 ;; *) exit 2 ;; esac

.PHONY: check coupling fmt-check unit smoke test

check: coupling
	for pkg in $(PACKAGES); do (cd $$pkg && $(AGENTICA) check .) || exit 1; done

coupling:
	@$(call none,$(LEAVES) depend on the server or a client,$(foreach p,$(LEAVES),-g '$(p)/**') \
	  -e 'subdir *= *"($(SERVER_AND_CLIENTS))"' -e '"pkg/($(SERVER_AND_CLIENTS))/' .)
	@$(call none,a package imports another package's src/ (use its public module),-g '*.agc' 'pkg/[a-z0-9_-]+/src/' .)

fmt-check:
	for pkg in $(PACKAGES); do (cd $$pkg && $(AGENTICA) fmt --check .) || exit 1; done

# A package whose run passes no test fails, so tests that are no longer found never pass in silence.
unit:
	for pkg in $(PACKAGES); do \
	  out=$$(cd $$pkg && $(AGENTICA) test tests); status=$$?; echo "$$out"; [ $$status -eq 0 ] || exit 1; \
	  echo "$$out" | tail -n 1 | grep -Eq '^[1-9][0-9]* passed' || { echo "unit: no test passed in $$pkg" >&2; exit 1; }; \
	done

# The core's entry point runs, with llm read from the workspace.
smoke:
	out=$$($(AGENTICA) core/main.agc --version) && echo "$$out" | grep -qx 'agc-agent core [0-9.]* (llm [0-9.]*)'

test: check unit smoke
