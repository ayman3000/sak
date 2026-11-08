PREFIX ?= /usr/local

.PHONY: build install uninstall clean

build:
	swift build -c release

install: build
	ln -sf "$(CURDIR)/.build/release/sak" "$(PREFIX)/bin/sak"
	@echo "installed: $(PREFIX)/bin/sak"

uninstall:
	rm -f "$(PREFIX)/bin/sak"

clean:
	swift package clean
