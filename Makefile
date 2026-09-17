SWIFTC = xcrun swiftc
PREFIX ?= $(HOME)/.local

.PHONY: all install test clean
all: build/resolve-archive

build/resolve-archive: Sources/main.swift Sources/Publish.swift
	mkdir -p build
	$(SWIFTC) -O -module-cache-path build/module-cache $^ -o $@

install: all
	install -d "$(PREFIX)/bin"
	install -m 755 build/resolve-archive "$(PREFIX)/bin/resolve-archive"

test: all
	$(SWIFTC) -module-cache-path build/module-cache Sources/Publish.swift tests/publish-tests.swift -o build/publish-tests
	build/publish-tests
	python3 tests/test_archive.py

clean:
	rm -rf build
