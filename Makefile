PREFIX ?= /usr/local

.PHONY: build install uninstall clean smoke

build:
	swift build -c release

install: build
	ln -sf "$(CURDIR)/.build/release/sak" "$(PREFIX)/bin/sak"
	@echo "installed: $(PREFIX)/bin/sak"

uninstall:
	rm -f "$(PREFIX)/bin/sak"

# Three real one-shots (question, read-only review, edit) with their numbers —
# the check after a SwiftAgentKit change. Needs a model (Ollama by default).
smoke: build
	SAK=.build/release/sak sh scripts/smoke.sh

clean:
	swift package clean
