PREFIX ?= $(HOME)/.local

borders: borders.swift
	swiftc -O -wmo -swift-version 5 borders.swift -o borders
	strip -x borders
	codesign -f -s - -i local.borders-native borders

install: borders
	install -m 755 borders $(PREFIX)/bin/borders-native

.PHONY: install
