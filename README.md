# Vineport

Run Windows **Steam** and **Epic Games** titles on macOS (Apple Silicon & Intel) using open-source Wine + Apple's Game Porting Toolkit — no CrossOver license needed.

## What is this?

A native macOS launcher that runs Windows games through [Wine](https://www.winehq.org/), rendering DirectX with Apple's **Game Porting Toolkit (D3DMetal)** when available (and DXVK/MoltenVK as a fallback). It includes a SwiftUI app with a game library plus a `vineport` command-line tool.

**Tested on:** macOS 14+ with Apple Silicon (M1/M2/M3/M4) via Rosetta 2.

## Download

Grab the latest **Vineport.zip** from the [Releases](https://github.com/MelonForAll/vineport/releases) page. Unzip it, drag **Vineport.app** to your Applications folder (or anywhere), and double-click. On first launch it downloads Wine (~190 MB) and sets everything up automatically.

> **Note:** Since the app is not notarized, macOS will block it on first open. Right-click the app and select "Open" to bypass Gatekeeper.

For DirectX 12 games, also install Apple's Game Porting Toolkit:
```bash
brew install --cask gcenx/wine/game-porting-toolkit
```

## Quick Start (from source)

```bash
git clone https://github.com/MelonForAll/vineport.git
cd vineport

# Download Wine Staging (~190 MB)
chmod +x setup.sh
./setup.sh

# Launch the Steam client
./launch-steam.sh

# …or use the CLI
./vineport games            # list installed Steam games
./vineport launch <appid>   # launch a game
./vineport epic games       # list your Epic library (via legendary)
```

Or double-click **Vineport.app** after running setup.

## How it works

1. `setup.sh` downloads [Wine Staging](https://github.com/Gcenx/macOS_Wine_builds) (pre-built x86_64 Wine for macOS).
2. The launch scripts create a Wine prefix, install Steam, and run games.
3. On Apple Silicon, everything runs through Rosetta 2 (x86_64 → ARM).
4. DirectX rendering: **Game Porting Toolkit (D3DMetal)** when installed, else DirectX → Wine → DXVK/vkd3d → Vulkan → MoltenVK → Metal.

## Game Compatibility

- **Works well:** Most indie games, many AAA single-player titles, DX9/10/11 games. With **Apple's Game Porting Toolkit** installed, DirectX 12 games also work (Vineport launches them through GPTK's D3DMetal — verified with Elden Ring).
- **DirectX 12 without GPTK:** the bundled vkd3d-proton → MoltenVK path can't initialize D3D12 on macOS, so **install Game Porting Toolkit** for DX12 titles (see Download).
- **Anti-cheat (EAC, BattlEye, Vanguard):** Online/multiplayer is **not supported** — Vineport does not circumvent anti-cheat. Many titles that bundle anti-cheat still have a singleplayer/offline mode; for those, Vineport offers a **"Play Offline (No Anti-Cheat)"** launch that runs the game without its anti-cheat. This only works offline.

Check [ProtonDB](https://www.protondb.com/) for game-specific reports — if a game runs on Linux/Proton, it will likely work here.

## Performance Tips

- The launchers enable `WINEMSYNC`/`WINEESYNC` by default for better sync performance.
- D3D12 games are most reliable through the Game Porting Toolkit path.
- Close unnecessary background apps to free up resources for Rosetta 2.

## Building from Source

Pre-built binaries are not included in the repo. The app works from the shell scripts directly, but you can build the distributable `.app`:

```bash
brew install mingw-w64      # for the steamwebhelper wrapper

make bundle                 # build the self-contained app → dist/Vineport.app
make release                # also produce dist/Vineport.zip
```

Individual targets:
```bash
make wrapper          # build steamwebhelper_wrapper.exe only
make app              # build the SwiftUI app binary
make install-wrapper  # install the wrapper into an existing Wine prefix
```

The **steamwebhelper wrapper** (`webhelper_wrapper.c`) intercepts Steam's CEF browser process and injects flags needed for Wine compatibility — without it, Steam's UI renders as a black screen.

## File Structure

```
vineport/
├── VineportApp.swift        # Native SwiftUI app (game library + launcher)
├── vineport                 # CLI: games, launch, profiles, epic
├── common.sh                # Shared launch helpers (Wine/GPTK, exe detection)
├── setup.sh                 # Downloads & installs Wine Staging
├── launch-steam.sh          # Launch the Steam client
├── launch-steam-game.sh     # Launch a Steam game directly (offline)
├── launch-steam-gptk.sh     # Launch via Game Porting Toolkit (D3DMetal)
├── launch-epic-game.sh      # Launch an Epic game (via legendary)
├── dismiss-dialogs.sh       # Auto-dismisses Steam error popups
├── build-wine.sh            # Build a clean Wine from source (optional)
├── webhelper_wrapper.c      # steamwebhelper Wine-compat wrapper (source)
├── Makefile                 # Build targets (app, wrapper, bundle, release)
├── .github/workflows/ci.yml # ShellCheck + Swift build CI
├── LICENSE
└── README.md
```

## Troubleshooting

**Steam shows a black screen:** Steam auto-updates can overwrite the webhelper wrapper. Re-run `make install-wrapper`, or just relaunch — `launch-steam.sh` detects this and re-installs the wrapper automatically.

**Steam error popups (0x3XXX):** Harmless content-server errors under Wine; downloads still work. `dismiss-dialogs.sh` auto-closes them (grant Accessibility if prompted).

**"wine server failed to run":** Run `setup.sh` first — the Wine runtime needs its `share/`/nls files.

**A D3D12 game crashes immediately:** Install the Game Porting Toolkit (see Download) — the bundled D3D12 path doesn't work on macOS.

**Game crashes on launch:** Not all games work under Wine. Check ProtonDB for compatibility.

## Credits

- [Wine](https://www.winehq.org/) / [Wine Staging](https://github.com/wine-staging/wine-staging) — the Windows compatibility layer (LGPL)
- [Gcenx](https://github.com/Gcenx/macOS_Wine_builds) — pre-built Wine binaries for macOS
- Apple **Game Porting Toolkit** (D3DMetal) — DirectX → Metal translation
- [legendary](https://github.com/derrod/legendary) — open-source Epic Games launcher
- [MoltenVK](https://github.com/KhronosGroup/MoltenVK) / [DXVK](https://github.com/doitsujin/dxvk) — Vulkan → Metal and D3D → Vulkan

## Disclaimer

Steam is a trademark of Valve Corporation; Epic Games Store is a trademark of Epic Games, Inc. This project is not affiliated with or endorsed by either. Running their clients under Wine may not comply with their respective subscriber agreements — use at your own risk.

## License

MIT — see [LICENSE](LICENSE). Wine itself is LGPL v2.1.
