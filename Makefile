PREFIX ?= $(HOME)/.local

borders: borders.swift
	swiftc -O -wmo -swift-version 5 borders.swift -o borders
	strip -x borders
	codesign -f -s - -i local.borders-native borders

# Write a new file, then rename: overwriting a signed binary in place gets it killed
# by macOS (OS_REASON_CODESIGNING) because the kernel caches the old signature.
install: borders
	install -m 755 borders $(PREFIX)/bin/borders-native.new
	mv -f $(PREFIX)/bin/borders-native.new $(PREFIX)/bin/borders-native

.PHONY: install
