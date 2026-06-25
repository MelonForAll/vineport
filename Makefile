# Build targets for Vineport
# Requires: Xcode command line tools (swiftc), mingw-w64 (x86_64-w64-mingw32-gcc)

PREFIX ?= $(HOME)/Library/Application Support/Vineport
CEF_DIR = $(PREFIX)/drive_c/Program Files (x86)/Steam/bin/cef/cef.win64

# Bundle paths
BUNDLE = dist/Vineport.app
BUNDLE_CONTENTS = $(BUNDLE)/Contents
BUNDLE_MACOS = $(BUNDLE_CONTENTS)/MacOS
BUNDLE_RESOURCES = $(BUNDLE_CONTENTS)/Resources

.PHONY: all wrapper app clean install-wrapper bundle release bundle-clean \
       test-build test wine-source wine-clean

all: wrapper app

# ── Developer targets (git-clone workflow) ────────────────────────────

# Windows PE wrapper for steamwebhelper (requires mingw-w64)
# Install mingw-w64: brew install mingw-w64
wrapper: steamwebhelper_wrapper.exe

steamwebhelper_wrapper.exe: webhelper_wrapper.c
	x86_64-w64-mingw32-gcc -O2 -o $@ $<

# Native macOS SwiftUI app
app: Vineport.app/Contents/MacOS/Vineport

Vineport.app/Contents/MacOS/Vineport: VineportApp.swift
	@mkdir -p Vineport.app/Contents/MacOS
	swiftc -O -parse-as-library -o $@ $<
	codesign --force --deep -s - Vineport.app

# Copy the webhelper wrapper into the Wine prefix
install-wrapper: steamwebhelper_wrapper.exe
	@if [ ! -f "$(CEF_DIR)/steamwebhelper.exe" ]; then \
		echo "Error: Steam not installed in prefix yet. Run launch-steam.sh first."; \
		exit 1; \
	fi
	@if [ ! -f "$(CEF_DIR)/steamwebhelper_real.exe" ]; then \
		cp "$(CEF_DIR)/steamwebhelper.exe" "$(CEF_DIR)/steamwebhelper_real.exe"; \
	fi
	cp steamwebhelper_wrapper.exe "$(CEF_DIR)/steamwebhelper.exe"
	@echo "Wrapper installed."

# ── Distribution targets (self-contained .app) ───────────────────────

bundle: wrapper
	@echo "Assembling Vineport.app..."
	rm -rf dist/
	mkdir -p "$(BUNDLE_MACOS)" "$(BUNDLE_RESOURCES)"
	# Compile Swift app
	swiftc -O -parse-as-library -o "$(BUNDLE_MACOS)/Vineport" VineportApp.swift
	# Info.plist
	@echo '<?xml version="1.0" encoding="UTF-8"?>' > "$(BUNDLE_CONTENTS)/Info.plist"
	@echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> "$(BUNDLE_CONTENTS)/Info.plist"
	@echo '<plist version="1.0"><dict>' >> "$(BUNDLE_CONTENTS)/Info.plist"
	@echo '<key>CFBundleExecutable</key><string>Vineport</string>' >> "$(BUNDLE_CONTENTS)/Info.plist"
	@echo '<key>CFBundleIdentifier</key><string>com.melonforall.vineport</string>' >> "$(BUNDLE_CONTENTS)/Info.plist"
	@echo '<key>CFBundleName</key><string>Vineport</string>' >> "$(BUNDLE_CONTENTS)/Info.plist"
	@echo '<key>CFBundleVersion</key><string>2.0</string>' >> "$(BUNDLE_CONTENTS)/Info.plist"
	@echo '<key>NSAppleEventsUsageDescription</key><string>Vineport needs accessibility to dismiss game dialogs.</string>' >> "$(BUNDLE_CONTENTS)/Info.plist"
	@echo '</dict></plist>' >> "$(BUNDLE_CONTENTS)/Info.plist"
	# Copy runtime resources
	cp common.sh "$(BUNDLE_RESOURCES)/"
	cp launch-steam.sh "$(BUNDLE_RESOURCES)/"
	cp launch-steam-game.sh "$(BUNDLE_RESOURCES)/"
	cp launch-steam-gptk.sh "$(BUNDLE_RESOURCES)/"
	cp launch-epic-game.sh "$(BUNDLE_RESOURCES)/"
	cp setup.sh "$(BUNDLE_RESOURCES)/"
	cp dismiss-dialogs.sh "$(BUNDLE_RESOURCES)/"
	cp steamwebhelper_wrapper.exe "$(BUNDLE_RESOURCES)/"
	# The CLI lives on disk as `winesteam`; ship it as `vineport`.
	cp winesteam "$(BUNDLE_RESOURCES)/vineport"
	chmod +x "$(BUNDLE_RESOURCES)"/*.sh "$(BUNDLE_RESOURCES)/vineport"
	# Ad-hoc code sign
	codesign --force --deep -s - "$(BUNDLE)"
	@echo ""
	@echo "Bundle ready at dist/Vineport.app"
	@echo "Test with: open dist/Vineport.app"

release: bundle
	cd dist && zip -r Vineport.zip Vineport.app
	@echo "Release archive: dist/Vineport.zip"

# ── Anti-cheat test targets ───────────────────────────────────────────

# Compile all test binaries
test-build: tests/mach_syscall_test tests/nt_api_check.exe

# Mach exception handler syscall interception PoC (native x86_64)
tests/mach_syscall_test: tests/mach_syscall_test.c
	clang -arch x86_64 -O0 -o $@ $< -lpthread

# NT API validation (Windows PE, runs under Wine)
tests/nt_api_check.exe: tests/nt_api_check.c
	x86_64-w64-mingw32-gcc -O2 -o $@ $< -lntdll

# Run all tests
test: test-build
	./tests/run_tests.sh

# ── Wine from source (anti-cheat patches) ────────────────────────────

wine-source:
	./build-wine.sh

wine-clean:
	./build-wine.sh --clean

# ── Cleanup ───────────────────────────────────────────────────────────

clean:
	rm -f steamwebhelper_wrapper.exe
	rm -f Vineport.app/Contents/MacOS/Vineport
	rm -f tests/mach_syscall_test tests/nt_api_check.exe

bundle-clean:
	rm -rf dist/
