# mantel-blocks build commands. Run from the repository root.
#
# The kit comes by URL (https://github.com/ytchou/mantel.git). With
# MANTEL=<path to a Mantel checkout> it comes from that checkout instead,
# and `make test` also runs the collision tests in tests/collisions.

# Each block: <id>:<executable>. The id is its folder under blocks/.
BLOCKS := nowplaying:NowPlaying rename:Rename shelf:Shelf
OUT    := build

# MANTEL may be relative (to this folder) or start with ~ (zsh passes a
# literal ~ in `make package MANTEL=~/...`). Make it absolute once, so every
# swift invocation and manifest sees the same path; the manifests refuse a
# relative one.
ifdef MANTEL
override MANTEL := $(abspath $(patsubst ~/%,$(HOME)/%,$(patsubst ~,$(HOME),$(MANTEL))))
export MANTEL
endif
ifdef BLOCK_SIGN_IDENTITY
export BLOCK_SIGN_IDENTITY
endif
ifdef BLOCK_SIGN_TIMESTAMP
export BLOCK_SIGN_TIMESTAMP
endif

.PHONY: build test package clean

build: ## Build every block (debug)
	@set -e; for b in $(BLOCKS); do id=$${b%%:*}; \
		echo "== blocks/$$id"; swift build --package-path blocks/$$id; \
	done

test: ## Test every block; with MANTEL set, also the collision tests
	@set -e; for b in $(BLOCKS); do id=$${b%%:*}; \
		echo "== blocks/$$id"; swift test --package-path blocks/$$id; \
	done
ifdef MANTEL
	@# Debug only: the collision tests use @testable import from path
	@# dependencies, so `swift test -c release` is not supported.
	@echo "== tests/collisions"
	swift test --package-path tests/collisions
else
	@echo "== tests/collisions skipped: it needs MANTEL=<path to a Mantel checkout>"
endif

# Signed with BLOCK_SIGN_IDENTITY when set, else ad hoc. BLOCK_SIGN_TIMESTAMP
# is passed on to package-block.sh ("none" signs without a timestamp).
package: ## Package every block into build/<Name>.mantelblock
	@set -e; mkdir -p $(OUT); for b in $(BLOCKS); do id=$${b%%:*}; exe=$${b##*:}; \
		swift build --package-path blocks/$$id --product $$exe; \
		if [ -n "$$MANTEL" ]; then script="$$MANTEL/Packages/BlockKit/Scripts/package-block.sh"; \
		else script="blocks/$$id/.build/checkouts/mantel/Packages/BlockKit/Scripts/package-block.sh"; fi; \
		sh "$$script" blocks/$$id/.build/debug/$$exe blocks/$$id/manifest.json $(OUT); \
	done

clean: ## Delete build output and each package's .build
	rm -rf $(OUT) tests/collisions/.build $(foreach b,$(BLOCKS),blocks/$(firstword $(subst :, ,$(b)))/.build)
