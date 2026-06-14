# etylizer browser editor — build pipeline.
#
#   make                 pthreads build (DEFAULT): persistent warm BEAM, needs SAB/COI
#   make THREADS=single  single-threaded build (on-demand): per-check worker, no SAB
#   make docs            publish docs/ (ALWAYS pthreads): index.html + coi-serviceworker.js
#   make serve           serve _build/web/  (http://localhost:$(PORT)/editor.html)
#   make release         one self-contained page in _build/release/
#   make clean / distclean
#
# THREADS picks the albsch/erlang-otp-wasm branch + editor frontend:
#   pthreads -> otp-pthreads        branch, editor.pthreads.html, coi-serviceworker.js  (docs/)
#   single   -> otp-single-threaded branch, editor.single.html,   beam-worker.js
# Each branch is cloned once into _build/erlang-otp-wasm-$(THREADS); _build/erlang-otp-wasm
# (the path the build scripts hardcode) is a symlink to the active one, so switching modes
# just re-points it — no re-download, each mode's OTP build stays cached.
#
# Requires: native OTP matching erlang-otp-wasm, rebar3, git, python3, and uv (`make serve`).

ETYLIZER_REPO  ?= https://github.com/etylizer/etylizer.git
ETYLIZER_REF   ?= as/etylizer-wasm
EDITOR_VERSION ?= v0.0.1
PORT           ?= 8000
THREADS        ?= pthreads
export ETYLIZER_REPO ETYLIZER_REF THREADS

ifeq ($(THREADS),pthreads)
  OTP_WASM_REF := otp-pthreads
  EDITOR_PAGE  := editor.pthreads.html
  EXTRA_WEB    := web/coi-serviceworker.js
else ifeq ($(THREADS),single)
  OTP_WASM_REF := otp-single-threaded
  EDITOR_PAGE  := editor.single.html
  EXTRA_WEB    := web/beam-worker.js
else
  $(error THREADS must be 'pthreads' or 'single', got '$(THREADS)')
endif

.PHONY: all otp-wasm web image docs release serve serve-release clean distclean

all:
	$(MAKE) otp-wasm
	$(MAKE) web
	$(MAKE) image

# Clone the selected branch once into a per-mode dir, then point _build/erlang-otp-wasm
# (hardcoded by the build scripts) at it. Switching THREADS just re-links.
otp-wasm:
	@[ -d _build/erlang-otp-wasm-$(THREADS)/.git ] || \
	 git clone -q --branch $(OTP_WASM_REF) --depth 1 https://github.com/albsch/erlang-otp-wasm.git _build/erlang-otp-wasm-$(THREADS)
	@git -C _build/erlang-otp-wasm-$(THREADS) rev-parse --short=12 HEAD > _build/erlang-otp-wasm.commit 2>/dev/null || true
	@[ -L _build/erlang-otp-wasm ] || rm -rf _build/erlang-otp-wasm
	@ln -sfn erlang-otp-wasm-$(THREADS) _build/erlang-otp-wasm
	@./scripts/resolve-emsdk.sh; export EMSDK=_build/emsdk; \
	 _build/erlang-otp-wasm/wasm/build-otp-wasm.sh all

# Stage _build/web/: the selected page (as editor.html), its mode helper
# (coi-serviceworker.js | beam-worker.js), and Ace. beam.{js,wasm,data} come from 'image'.
web:
	mkdir -p _build/web/ace
	cp web/$(EDITOR_PAGE) _build/web/editor.html
	cp $(EXTRA_WEB) _build/web/
	cp vendor/ace/*.min.js _build/web/ace/
	@commit=$$(cat _build/etylizer.commit 2>/dev/null); \
	 [ -n "$$commit" ] || commit=$$(git ls-remote $(ETYLIZER_REPO) $(ETYLIZER_REF) 2>/dev/null | cut -c1-12); \
	 [ -n "$$commit" ] || commit="$(ETYLIZER_REF)"; \
	 otp=$$(cat _build/erlang-otp-wasm/OTP_VERSION 2>/dev/null); [ -n "$$otp" ] || otp="unknown"; \
	 erts=$$(sed -n 's/^VSN[[:space:]]*=[[:space:]]*//p' _build/erlang-otp-wasm/erts/vsn.mk 2>/dev/null | head -1); [ -n "$$erts" ] || erts="unknown"; \
	 wasm=$$(cat _build/erlang-otp-wasm.commit 2>/dev/null); \
	 [ -n "$$wasm" ] || wasm=$$(git -C _build/erlang-otp-wasm rev-parse --short=12 HEAD 2>/dev/null); \
	 [ -n "$$wasm" ] || wasm=$$(git ls-remote https://github.com/albsch/erlang-otp-wasm.git $(OTP_WASM_REF) 2>/dev/null | cut -c1-12); \
	 [ -n "$$wasm" ] || wasm="$(OTP_WASM_REF)"; \
	 elixir=$$(tr -d '\n' < _build/elixir/lib/elixir/ebin/elixir.app 2>/dev/null | sed -n 's/.*{vsn,[ ]*"\([0-9.]*\)".*/\1/p'); \
	 [ -n "$$elixir" ] || elixir=$$(unzip -p vendor/elixir.zip 'lib/elixir/ebin/elixir.app' 2>/dev/null | tr -d '\n' | sed -n 's/.*{vsn,[ ]*"\([0-9.]*\)".*/\1/p'); \
	 [ -n "$$elixir" ] || elixir="unknown"; \
	 sed -i -e "s|__ETY_COMMIT__|$$commit|g" \
	        -e "s|__OTP_VERSION__|$$otp|g" \
	        -e "s|__ERTS_VERSION__|$$erts|g" \
	        -e "s|__WASM_COMMIT__|$$wasm|g" \
	        -e "s|__ELIXIR_VERSION__|$$elixir|g" \
	        -e "s|__EDITOR_VERSION__|$(EDITOR_VERSION)|g" _build/web/editor.html; \
	 echo "web ($(THREADS)): page=$(EDITOR_PAGE) commit=$$commit otp=$$otp erts=$$erts elixir=$$elixir wasm=$$wasm editor=$(EDITOR_VERSION)"

image:
	./scripts/build-image.sh

# docs/ is ALWAYS the pthreads build (warm BEAM). A service worker must be a separate
# file at a stable URL, so docs/ = self-contained index.html + coi-serviceworker.js.
docs:
	$(MAKE) THREADS=pthreads otp-wasm image release
	cp _build/release/etylizer-editor.html docs/index.html
	cp _build/release/coi-serviceworker.js docs/
	touch docs/.nojekyll
	@echo "docs/ staged (pthreads): index.html + coi-serviceworker.js + .nojekyll"

release: web
	ETY_THREADS=$(THREADS) python3 build-release.py

serve: web
	uv run --no-project python -m http.server $(PORT) --directory _build/web

serve-release:
	uv run --no-project python -m http.server $(PORT) --directory _build/release

clean:
	rm -rf _build/staging _build/web _build/release

distclean: clean
	rm -rf _build
