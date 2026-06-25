# WineSteam

Run Windows Steam on macOS (Apple Silicon & Intel) using open-source Wine — no CrossOver license needed.

## What is this?

A lightweight launcher that uses [Wine Staging](https://www.winehq.org/) to run the Windows version of Steam on macOS. This lets you play Windows-only games on your Mac.

**Tested on:** macOS 14+ with Apple Silicon (M1/M2/M3/M4) via Rosetta 2.

## Download

Grab the latest **WineSteam.zip** from the [Releases](https://github.com/melonforall/winesteam/releases) page. Unzip it, drag **WineSteam.app** to your Applications folder (or anywhere), and double-click. On first launch it will download Wine (~190 MB) and set everything up automatically.

> **Note:** Since the app is not notarized, macOS will block it on first open. Right-click the app and select "Open" to bypass Gatekeeper.

## Quick Start (from source)

If you prefer the command line or want to hack on it:

```bash
# Clone the repo
git clone https://github.com/melonforall/winesteam.git
cd winesteam

# Run setup (downloads Wine Staging ~190MB)
chmod +x setup.sh
./setup.sh

# Launch Steam
./launch-steam.sh
```

Or double-click **WineSteam.app** after running setup.

## How it works

1. `setup.sh` downloads [Wine Staging](https://github.com/Gcenx/macOS_Wine_builds) (pre-built x86_64 Wine for macOS)
2. `launch-steam.sh` creates a Wine prefix, installs Steam, and launches it
3. On Apple Silicon, everything runs through Rosetta 2 (x86_64 -> ARM translation)
4. DirectX games go through: DirectX -> Wine -> Vulkan -> MoltenVK -> Metal

## Game Compatibility

- **Works well:** Most indie games, many AAA single-player titles, DX9/10/11 games. With **Apple's Game Porting Toolkit** installed, DirectX 12 games also work (Vineport launches them through GPTK's D3DMetal — verified with Elden Ring).
- **DirectX 12 without GPTK:** the bundled vkd3d-proton → MoltenVK path can't initialize D3D12 on macOS, so **install Game Porting Toolkit** for DX12 titles: `brew install --cask gcenx/wine/game-porting-toolkit`.
- **Anti-cheat (EAC, BattlEye, Vanguard):** Online/multiplayer is **not supported** — Vineport does not circumvent anti-cheat. Many titles that bundle anti-cheat still have a singleplayer/offline mode; for those, Vineport offers a **"Play Offline (No Anti-Cheat)"** launch that runs the game without its anti-cheat. This only works offline.

Check [ProtonDB](https://www.protondb.com/) for game-specific reports — if a game runs on Linux/Proton, it will likely work here.

## Performance Tips

- The launcher enables `WINEMSYNC` and `WINEESYNC` by default for better sync performance
- For DirectX -> Metal translation, consider adding [DXVK](https://github.com/doitsujin/dxvk) to `wine/lib/wine/dxvk/`
- Close unnecessary background apps to free up resources for Rosetta 2

## Building from Source

Pre-built binaries are not included in the repo. The app works out of the box using shell scripts, but you can build the distributable .app and native components:

```bash
# Install build dependencies
brew install mingw-w64

# Build the self-contained .app bundle (outputs to dist/)
make bundle

# Create a release zip
make release
```

This compiles the Swift launcher, builds the steamwebhelper wrapper, and assembles everything into `dist/WineSteam.app`.

You can also build individual components:

```bash
make wrapper          # Build steamwebhelper_wrapper.exe only
make launcher         # Build native launcher for the dev app bundle
make install-wrapper  # Install wrapper into existing Wine prefix
```

The **steamwebhelper wrapper** (`webhelper_wrapper.c`) intercepts Steam's CEF browser process and injects flags needed for Wine compatibility. Without it, Steam's UI renders as a black screen.

## File Structure

```
winesteam/
├── setup.sh                    # Downloads Wine Staging
├── launch-steam.sh             # Main launcher script
├── dismiss-dialogs.sh          # Auto-dismisses Steam error popups
├── Makefile                    # Build targets (bundle, wrapper, release)
├── webhelper_wrapper.c         # Source: steamwebhelper Wine-compat wrapper
├── webhelper-wrapper.cmd       # Batch file alternative (unused)
├── WineSteamLauncher.swift     # Source: native macOS launcher with setup UI
├── WineSteam.app/              # Dev app bundle (shell script launcher)
│   └── Contents/
│       ├── Info.plist
│       ├── MacOS/launch        # Shell script entry point
│       └── Resources/          # AppIcon.icns (provide your own)
├── dist/                       # Build output (from `make bundle`, gitignored)
│   └── WineSteam.app/          # Self-contained release app bundle
├── wine/                       # Wine runtime (from setup.sh, gitignored)
├── LICENSE
└── README.md
```

## Troubleshooting

**Steam shows a black screen:** Steam auto-updates can overwrite the webhelper wrapper, breaking CEF rendering. Re-run `make install-wrapper`, or just relaunch -- the launch script detects this and re-installs the wrapper automatically.

**Steam shows error popups (0x3XXX):** These are content server errors under Wine -- they're harmless and downloads still work. The `dismiss-dialogs.sh` script auto-closes them. Grant Accessibility permissions if prompted.

**"wine server failed to run":** Make sure you ran `setup.sh` first. The Wine runtime needs its share/nls files.

**No window appears:** Check `~/Library/Logs/WineSteam/` for the latest log file.

**Game crashes on launch:** Not all games work under Wine. Check ProtonDB for compatibility.

## Credits

- [Wine](https://www.winehq.org/) — the Windows compatibility layer (LGPL)
- [Wine Staging](https://github.com/wine-staging/wine-staging) — Wine with experimental patches
- [Gcenx](https://github.com/Gcenx/macOS_Wine_builds) — pre-built Wine binaries for macOS
- [MoltenVK](https://github.com/KhronosGroup/MoltenVK) — Vulkan -> Metal translation

## Disclaimer

Steam is a trademark of Valve Corporation. This project is not affiliated with or endorsed by Valve. Running Steam under Wine may not comply with Valve's Steam Subscriber Agreement — use at your own risk. Valve has historically been tolerant of Wine-based usage (they develop Proton), but makes no guarantees for third-party compatibility layers.

## License

MIT — see [LICENSE](LICENSE). Wine itself is LGPL v2.1.
