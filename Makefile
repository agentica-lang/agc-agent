AGENTICA ?= agentica

# The members of the workspace (agentica.toml): one folder per package, each with its own agentica.toml.
PACKAGES = llm core

.PHONY: check fmt-check unit smoke test

check:
	for pkg in $(PACKAGES); do (cd $$pkg && $(AGENTICA) check .) || exit 1; done

fmt-check:
	for pkg in $(PACKAGES); do (cd $$pkg && $(AGENTICA) fmt --check .) || exit 1; done

unit:
	for pkg in $(PACKAGES); do (cd $$pkg && $(AGENTICA) test tests) || exit 1; done

# The core's entry point runs, with llm read from the workspace.
smoke:
	$(AGENTICA) core/main.agc --version | grep -q '^agc-agent core [0-9.]* (llm [0-9.]*)$$'

test: check unit smoke
