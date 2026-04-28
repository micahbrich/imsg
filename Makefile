SHELL := /bin/bash

.PHONY: help build build-dylib build-helper dev test clean install uninstall

help:
	@printf "%s\n" \
		"make build       - compile TypeScript + build dylib" \
		"make build-dylib - build injectable dylib for Messages.app" \
		"make dev         - run CLI in development mode (ARGS=...)" \
		"make test        - run tests" \
		"make install     - install to /usr/local/bin" \
		"make uninstall   - remove from /usr/local/bin" \
		"make clean       - remove build artifacts"

build: build-dylib
	npm run build

# Build injectable dylib for Messages.app (DYLD_INSERT_LIBRARIES)
# Uses arm64e architecture to match Messages.app on Apple Silicon
build-dylib:
	@echo "Building imsg-plus-helper.dylib..."
	@mkdir -p .build/release
	@clang -dynamiclib -arch arm64e -fobjc-arc \
		-framework Foundation \
		-o .build/release/imsg-plus-helper.dylib \
		Sources/IMsgHelper/IMsgInjected.m
	@echo "Built .build/release/imsg-plus-helper.dylib"

# Legacy standalone helper
build-helper:
	@mkdir -p .build/release
	@clang -fobjc-arc -framework Foundation -o .build/release/imsg-helper Sources/IMsgHelper/main.m

dev: build-dylib
	npx tsx src/index.ts $(ARGS)

test:
	npx tsc --noEmit

clean:
	rm -rf dist
	rm -f .build/release/imsg-plus-helper.dylib
	rm -f .build/release/imsg-helper

install: build build-dylib
	@mkdir -p /usr/local/bin /usr/local/lib
	@cp .build/release/imsg-plus-helper.dylib /usr/local/lib/imsg-plus-helper.dylib
	@ln -sf $$(pwd)/dist/index.js /usr/local/bin/imsg
	@ln -sf $$(pwd)/dist/index.js /usr/local/bin/imsg-plus
	@chmod +x /usr/local/bin/imsg
	@chmod +x /usr/local/bin/imsg-plus
	@echo "Installed. Run 'imsg' or 'imsg-plus' from anywhere."
	@echo ""
	@echo "To enable typing/read receipts:"
	@echo "  1. Disable SIP"
	@echo "  2. imsg launch"

uninstall:
	@rm -f /usr/local/bin/imsg
	@rm -f /usr/local/bin/imsg-plus
	@rm -f /usr/local/lib/imsg-plus-helper.dylib
	@echo "Uninstalled."
