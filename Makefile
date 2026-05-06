# Build targets for WineSteam
# Requires: Xcode command line tools (swiftc), mingw-w64 (x86_64-w64-mingw32-gcc)

PREFIX ?= $(HOME)/Library/Application Support/WineSteam
CEF_DIR = $(PREFIX)/drive_c/Program Files (x86)/Steam/bin/cef/cef.win64

.PHONY: all wrapper launcher clean install-wrapper

all: wrapper launcher

# Windows PE wrapper for steamwebhelper (requires mingw-w64)
# Install mingw-w64: brew install mingw-w64
wrapper: steamwebhelper_wrapper.exe

steamwebhelper_wrapper.exe: webhelper_wrapper.c
	x86_64-w64-mingw32-gcc -O2 -o $@ $<

# Native macOS launcher (optional — the app works without it via the shell script)
launcher: WineSteam.app/Contents/MacOS/WineSteamLauncher

WineSteam.app/Contents/MacOS/WineSteamLauncher: WineSteamLauncher.swift
	swiftc -O -o $@ $<
	codesign --force --deep -s - WineSteam.app

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

clean:
	rm -f steamwebhelper_wrapper.exe
	rm -f WineSteam.app/Contents/MacOS/WineSteamLauncher
