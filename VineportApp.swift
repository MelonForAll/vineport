import SwiftUI
import Cocoa
import Foundation
import WebKit

// MARK: - Data Models

enum GameSource: String, Codable {
    case steam = "Steam"
    case epic = "Epic"
}

enum AntiCheatStatus: String {
    case none = "None"
    case eacEOS = "EAC (EOS)"
    case eacLegacy = "EAC (Legacy)"
    case battleye = "BattlEye"
    case unknown = "Unknown"
}

struct Game: Identifiable, Hashable {
    let id: String          // appid for Steam, app_name for Epic
    let name: String
    let source: GameSource
    let installDir: String
    let sizeBytes: Int64
    let isInstalled: Bool
    var antiCheat: AntiCheatStatus = .none
    var hasLinuxEAC: Bool = false
    var imageURL: String = ""  // cover art URL

    var sizeFormatted: String {
        if sizeBytes > 1_073_741_824 {
            return "\(sizeBytes / 1_073_741_824) GB"
        } else if sizeBytes > 1_048_576 {
            return "\(sizeBytes / 1_048_576) MB"
        } else if sizeBytes > 0 {
            return "\(sizeBytes / 1024) KB"
        }
        return "—"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(source)
    }

    static func == (lhs: Game, rhs: Game) -> Bool {
        lhs.id == rhs.id && lhs.source == rhs.source
    }
}

// MARK: - Game Scanner

// Find the full path to legendary, since .app bundles have a minimal PATH
class LegendaryLocator {
    static let shared = LegendaryLocator()
    // Resolved eagerly in init: `lazy var` is not thread-safe, and the first
    // accesses race in from two background queues (library scan + login check).
    let path: String
    init() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        // pip installs land in a Python-version-suffixed bin dir — enumerate
        // the versions actually present instead of hardcoding a list that rots.
        for base in ["/Library/Frameworks/Python.framework/Versions",
                     "\(home)/Library/Python"] {
            for v in ((try? fm.contentsOfDirectory(atPath: base)) ?? []).sorted().reversed() {
                candidates.append("\(base)/\(v)/bin/legendary")
            }
        }
        candidates.append(contentsOf: [
            "/usr/local/bin/legendary",
            "/opt/homebrew/bin/legendary",
            "\(home)/.local/bin/legendary",
        ])
        if let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            path = found
            return
        }
        // Last resort: try a login shell
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", "which legendary"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            // Bail before touching the pipe — reading with no child attached
            // blocks forever.
            path = "/usr/local/bin/legendary"
            return
        }
        // Read BEFORE waitUntilExit to avoid pipe buffer deadlock
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        proc.waitUntilExit()
        path = (!out.isEmpty && fm.isExecutableFile(atPath: out)) ? out : "/usr/local/bin/legendary"
    }
}

var legendaryPath: String { LegendaryLocator.shared.path }

class GameLibrary: ObservableObject {
    @Published var games: [Game] = []
    @Published var isScanning = false
    @Published var lastError: String?

    let supportDir: URL
    let steamAppsDir: URL
    let epicDir: URL
    let projectDir: URL  // git-clone dev directory

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        supportDir = home.appendingPathComponent("Library/Application Support/Vineport")

        // Find Wine: check project dir first (dev workflow), then support dir (bundle workflow)
        let binDir = URL(fileURLWithPath: (CommandLine.arguments[0] as NSString).deletingLastPathComponent)
        let possibleProjectDirs = [
            // Next to the binary
            binDir,
            // Directory containing the .app bundle
            // (binary is <repo>/Vineport.app/Contents/MacOS/Vineport)
            binDir.deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent(),
            // Common dev locations
            home.appendingPathComponent("vineport"),
            home.appendingPathComponent("opensource-wine-steam"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        ]

        // First candidate that looks like the git clone (has setup.sh) wins
        var foundProjectDir: URL? = nil
        for dir in possibleProjectDirs {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("setup.sh").path) {
                foundProjectDir = dir
                break
            }
        }

        projectDir = foundProjectDir ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        steamAppsDir = supportDir
            .appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps")
        epicDir = supportDir.appendingPathComponent("drive_c/Epic Games")
    }

    // Wine dir: prefer the project checkout, fall back to Application Support.
    // Computed (not stored) so it stays correct after setup installs Wine.
    var wineDir: URL {
        let repoWine = projectDir.appendingPathComponent("wine")
        if FileManager.default.isExecutableFile(
            atPath: repoWine.appendingPathComponent("bin/wine").path) {
            return repoWine
        }
        return supportDir.appendingPathComponent("wine")
    }

    var wineExists: Bool {
        FileManager.default.isExecutableFile(
            atPath: wineDir.appendingPathComponent("bin/wine").path)
    }

    func scan() {
        // No overlapping scans: they finish out of order, so a stale result
        // could overwrite a fresh one and clear the spinner early.
        guard !isScanning else { return }
        isScanning = true

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var found: [Game] = []

            // Scan Steam games (fast, local file reads)
            found.append(contentsOf: scanSteamGames())

            // Scan Epic games (may call legendary, slower)
            found.append(contentsOf: scanEpicGames())

            // Detect anti-cheat for all games
            for i in found.indices {
                detectAntiCheat(game: &found[i])
            }

            DispatchQueue.main.async {
                self.games = found.sorted { $0.name.lowercased() < $1.name.lowercased() }
                self.isScanning = false
            }
        }
    }

    private func scanSteamGames() -> [Game] {
        var games: [Game] = []
        let fm = FileManager.default

        guard fm.fileExists(atPath: steamAppsDir.path) else { return games }

        let enumerator = fm.enumerator(atPath: steamAppsDir.path)
        while let file = enumerator?.nextObject() as? String {
            enumerator?.skipDescendants()
            guard file.hasPrefix("appmanifest_"), file.hasSuffix(".acf") else { continue }

            let manifestPath = steamAppsDir.appendingPathComponent(file).path
            guard let content = try? String(contentsOfFile: manifestPath, encoding: .utf8) else { continue }

            let name = vdfGet(content, key: "name") ?? "Unknown"
            let appid = vdfGet(content, key: "appid") ?? ""
            let installdir = vdfGet(content, key: "installdir") ?? ""
            let sizeStr = vdfGet(content, key: "SizeOnDisk") ?? "0"
            let size = Int64(sizeStr) ?? 0

            // Skip redistributables
            if name.contains("Redistributable") || name.contains("Proton") { continue }

            let gameDir = steamAppsDir
                .appendingPathComponent("common")
                .appendingPathComponent(installdir)

            games.append(Game(
                id: appid,
                name: name,
                source: .steam,
                installDir: gameDir.path,
                sizeBytes: size,
                isInstalled: fm.fileExists(atPath: gameDir.path)
            ))
        }

        return games
    }

    private func scanEpicGames() -> [Game] {
        var games: [Game] = []
        let fm = FileManager.default

        // 1. Get all owned games from legendary (includes uninstalled)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: legendaryPath)
        proc.arguments = ["list", "--platform", "Windows", "--json"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            // legendary isn't installed — bail before touching the pipe, or
            // readDataToEndOfFile() would block forever (no child ever attached).
            return games
        }
        // Read BEFORE waitUntilExit to avoid pipe buffer deadlock
        let outData = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        // 2. Get installed games for cross-reference
        var installedApps: [String: [String: Any]] = [:]
        let installedPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/legendary/installed.json")
        if let installedData = try? Data(contentsOf: installedPath),
           let installedJson = try? JSONSerialization.jsonObject(with: installedData) as? [String: Any] {
            for (key, val) in installedJson {
                if let info = val as? [String: Any] {
                    installedApps[key] = info
                }
            }
        }

        // 3. Parse owned games list
        if let jsonArray = try? JSONSerialization.jsonObject(with: outData) as? [[String: Any]] {
            for entry in jsonArray {
                let metadata = entry["metadata"] as? [String: Any] ?? [:]
                let appName = entry["app_name"] as? String ?? ""
                let title = entry["app_title"] as? String
                    ?? metadata["title"] as? String
                    ?? appName

                // Skip DLCs and add-ons
                if let mainGameList = metadata["mainGameItemList"] as? [[String: Any]], !mainGameList.isEmpty {
                    // This is likely a DLC
                    if let categories = metadata["categories"] as? [[String: String]] {
                        let isDLC = categories.contains { $0["path"] == "addons" || $0["path"] == "dlc" }
                        if isDLC { continue }
                    }
                }

                // Extract cover art URL (prefer tall portrait, fall back to wide box)
                var imageURL = ""
                if let keyImages = metadata["keyImages"] as? [[String: Any]] {
                    let tall = keyImages.first { ($0["type"] as? String) == "DieselGameBoxTall" }
                    let wide = keyImages.first { ($0["type"] as? String) == "DieselGameBox" }
                    let thumb = keyImages.first { ($0["type"] as? String) == "Thumbnail" }
                    imageURL = (tall ?? wide ?? thumb)?["url"] as? String ?? ""
                }

                let installed = installedApps[appName]
                let installPath = installed?["install_path"] as? String ?? ""
                let installSize = installed?["install_size"] as? Int64 ?? 0
                // Game is installed if legendary tracks it — the directory should exist
                let isInstalled = installed != nil && !installPath.isEmpty

                games.append(Game(
                    id: appName,
                    name: title,
                    source: .epic,
                    installDir: installPath,
                    sizeBytes: installSize,
                    isInstalled: isInstalled,
                    imageURL: imageURL
                ))
            }
        }

        return games
    }

    private func detectAntiCheat(game: inout Game) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: game.installDir) else { return }

        let gameURL = URL(fileURLWithPath: game.installDir)

        // Check well-known root-level marker directories first — large games can
        // exceed the file cap below, so these must be detected regardless of it
        if let entries = try? fm.contentsOfDirectory(atPath: game.installDir) {
            for entry in entries {
                let name = entry.lowercased()
                if name == "easyanticheat_eos" {
                    game.antiCheat = .eacEOS
                } else if name == "easyanticheat" {
                    if game.antiCheat == .none { game.antiCheat = .eacLegacy }
                } else if name == "battleye" {
                    game.antiCheat = .battleye
                }
            }
        }

        // Recursively search for anti-cheat files (max depth 4)
        if let enumerator = fm.enumerator(at: gameURL, includingPropertiesForKeys: nil,
                                           options: [.skipsHiddenFiles]) {
            var depth = 0
            while let fileURL = enumerator.nextObject() as? URL {
                // Approximate depth limit
                let components = fileURL.pathComponents.count - gameURL.pathComponents.count
                if components > 4 {
                    enumerator.skipDescendants()
                    continue
                }

                let filename = fileURL.lastPathComponent.lowercased()

                // Bare "eac" substrings (beacon.dll, react.dll, ...) are not EAC —
                // only match the vendor name or an exact/prefixed "eac" component
                if filename.contains("easyanticheat") || filename == "eac" || filename.hasPrefix("eac_") {
                    if filename.contains("eos_setup") || filename.contains("_eos") {
                        game.antiCheat = .eacEOS
                    } else if game.antiCheat == .none {
                        game.antiCheat = .eacLegacy
                    }
                    if filename == "easyanticheat_x64.so" {
                        game.hasLinuxEAC = true
                    }
                }

                if filename.contains("battleye") || filename.contains("beservice") {
                    game.antiCheat = .battleye
                }

                depth += 1
                if depth > 5000 { break } // safety limit
            }
        }
    }

    private func vdfGet(_ content: String, key: String) -> String? {
        let pattern = "\"\(key)\"\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(content.startIndex..., in: content)
        if let match = regex.firstMatch(in: content, range: range) {
            if let valueRange = Range(match.range(at: 1), in: content) {
                return String(content[valueRange])
            }
        }
        return nil
    }
}

// MARK: - Wine/Game Process Manager

class ProcessManager: ObservableObject {
    @Published var isRunning = false
    @Published var currentGame: Game?
    @Published var outputLog: String = ""
    @Published var isSettingUp = false
    @Published var setupProgress: String = ""
    @Published var lastError: String?

    private var process: Process?
    private let library: GameLibrary

    init(library: GameLibrary) {
        self.library = library
    }

    var scriptDir: String {
        if let resourcePath = Bundle.main.resourcePath,
           FileManager.default.fileExists(atPath: "\(resourcePath)/launch-steam.sh") {
            return resourcePath
        }
        // Dev mode: use project directory from library
        let projDir = library.projectDir.path
        if FileManager.default.fileExists(atPath: "\(projDir)/launch-steam.sh") {
            return projDir
        }
        // Fallback: current directory
        let cwd = FileManager.default.currentDirectoryPath
        if FileManager.default.fileExists(atPath: "\(cwd)/launch-steam.sh") {
            return cwd
        }
        // Last resort: walk up from the binary — for an .app bundle the repo is
        // three levels up (binary -> Contents/MacOS -> Contents -> .app -> repo)
        let binary = CommandLine.arguments[0]
        var dir = (binary as NSString).deletingLastPathComponent
        for _ in 0..<3 {
            dir = (dir as NSString).deletingLastPathComponent
            if FileManager.default.fileExists(atPath: "\(dir)/launch-steam.sh") {
                return dir
            }
        }
        return cwd
    }

    func launchSteam() {
        let script = "\(scriptDir)/launch-steam.sh"
        runProcess(path: "/bin/bash", arguments: [script])
    }

    enum LaunchMode: String {
        case normal = "Normal"
        case noEAC = "No Anti-Cheat (Offline)"
        case gptk = "GPTK (Offline)"
    }

    func launchGame(_ game: Game, mode: LaunchMode = .normal) {
        guard !isRunning else { return }
        currentGame = game
        outputLog = "Launching \(game.name) [\(mode.rawValue)]...\n"

        switch game.source {
        case .steam:
            switch mode {
            case .gptk:
                // Launch directly via Apple GPTK Wine (D3D12→Metal, offline)
                let script = "\(scriptDir)/launch-steam-gptk.sh"
                runProcess(path: "/bin/bash", arguments: [script, game.id])
            case .noEAC:
                // Offline/singleplayer: run the game's exe directly (no anti-cheat)
                let script = "\(scriptDir)/launch-steam-game.sh"
                runProcess(path: "/bin/bash", arguments: [script, game.id, "--no-eac"])
            case .normal:
                let script = "\(scriptDir)/launch-steam.sh"
                runProcess(path: "/bin/bash", arguments: [script, "-applaunch", game.id])
            }
        case .epic:
            let script = "\(scriptDir)/launch-epic-game.sh"
            let gameDir = game.installDir

            outputLog += "Game dir: \(gameDir)\n"
            outputLog += "Mode: \(mode.rawValue)\n\n"

            switch mode {
            case .noEAC:
                runProcess(path: "/bin/bash", arguments: [script, gameDir, "--no-eac"])
            case .normal, .gptk:
                // Use legendary for the launch (handles Epic auth / cloud saves),
                // pointing it at GPTK/D3DMetal when installed (reliable for D3D12).
                let gptkWine = "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64"
                let useGPTK = FileManager.default.fileExists(atPath: gptkWine)
                let wineBin = useGPTK ? gptkWine : library.wineDir.appendingPathComponent("bin/wine").path
                if useGPTK {
                    // Dedicated GPTK prefix, same rule as launch-steam-gptk.sh:
                    // GPTK's Wine (7.7) must never reconfigure the bundled Wine
                    // (11.7) prefix. Prefix init can take a few seconds the first
                    // time, so do it off the main thread before launching.
                    // Mark running now so the UI shows progress and a second
                    // click can't start a duplicate launch during the prep.
                    isRunning = true
                    outputLog += "Preparing GPTK prefix...\n"
                    let shared = library.supportDir.path
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        guard let self = self else { return }
                        let prefix = self.ensureGPTKPrefix(sharedPrefix: shared, gptkWine: gptkWine)
                        DispatchQueue.main.async {
                            self.runProcess(path: legendaryPath, arguments: [
                                "launch", game.id,
                                "--wine", wineBin,
                                "--wine-prefix", prefix
                            ], gptk: true, winePrefix: prefix)
                        }
                    }
                } else {
                    runProcess(path: legendaryPath, arguments: [
                        "launch", game.id,
                        "--wine", wineBin,
                        "--wine-prefix", library.supportDir.path
                    ])
                }
            }
        }
    }

    func runSetup() {
        isSettingUp = true
        setupProgress = "Downloading Wine..."

        let script = "\(scriptDir)/setup.sh"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        if scriptDir.contains(".app/Contents/Resources") {
            // Bundle layout: Wine lives in Application Support (matches
            // vineport_resolve_wine in common.sh).
            let targetDir = library.supportDir.appendingPathComponent("wine").path
            proc.arguments = [script, "--target-dir", targetDir, "--quiet"]
        } else {
            // Git-clone layout: install to <repo>/wine (setup.sh's default,
            // with the bin/lib/share symlinks) — the launch scripts and CLI
            // look there first in this layout.
            proc.arguments = [script, "--quiet"]
        }

        let pipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = errPipe

        // Capture stderr so the real failure reason (checksum mismatch, extract
        // error, ...) can be surfaced instead of a generic network message.
        var errLog = ""
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                errLog += text
                if errLog.count > 20000 { errLog = String(errLog.suffix(10000)) }
            }
        }

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }

            for l in line.split(separator: "\n") {
                let text = String(l)
                if text.hasPrefix("PROGRESS:") {
                    let status = String(text.dropFirst(9))
                    DispatchQueue.main.async {
                        switch status {
                        case "downloading": self?.setupProgress = "Downloading Wine Staging..."
                        case "verifying": self?.setupProgress = "Verifying checksum..."
                        case "extracting": self?.setupProgress = "Extracting..."
                        case "done": self?.setupProgress = "Done!"
                        default: self?.setupProgress = status
                        }
                    }
                }
            }
        }

        proc.terminationHandler = { [weak self] p in
            // Stop both readers (a never-cleared readabilityHandler busy-fires
            // forever after EOF, pinning a core), then drain remaining stderr.
            pipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let remaining = errPipe.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                if let text = String(data: remaining, encoding: .utf8), !text.isEmpty {
                    errLog += text
                }
                self?.isSettingUp = false
                if p.terminationStatus == 0 {
                    self?.lastError = nil
                    self?.library.scan()
                } else {
                    // Show the script's last stderr lines (the real diagnostics)
                    // rather than unconditionally blaming the network.
                    let tail = errLog
                        .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .suffix(3)
                        .joined(separator: "\n")
                    let msg = tail.isEmpty
                        ? "Setup failed (exit \(p.terminationStatus)). Check your connection and try again."
                        : "Setup failed (exit \(p.terminationStatus)):\n\(tail)"
                    self?.setupProgress = msg
                    self?.lastError = msg
                }
            }
        }

        do {
            try proc.run()
        } catch {
            // run() threw — the termination handler will never fire, so clear the
            // spinner here and surface the error (otherwise setup hangs forever).
            pipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { [weak self] in
                self?.isSettingUp = false
                let msg = "Couldn't start setup: \(error.localizedDescription)"
                self?.setupProgress = msg
                self?.lastError = msg
            }
        }
    }

    // One-time init + game-library symlinks for the dedicated GPTK prefix, via
    // the same common.sh helper the launch scripts use (single source of truth).
    // Returns the dedicated prefix path; if the helper fails, GPTK's Wine will
    // still auto-initialize the prefix on first launch (only the symlinks and
    // pre-warmed registry are lost).
    private func ensureGPTKPrefix(sharedPrefix: String, gptkWine: String) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c",
            "source \"$1/common.sh\" && vineport_gptk_prefix \"$2\" \"$3\"",
            "vineport", scriptDir, sharedPrefix, gptkWine]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {}
        return sharedPrefix + "-gptk"
    }

    private func runProcess(path: String, arguments: [String], gptk: Bool = false, winePrefix: String? = nil) {
        isRunning = true

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = winePrefix ?? library.supportDir.path
        env["WINEARCH"] = "win64"
        if env["WINEDEBUG"] == nil { env["WINEDEBUG"] = "-all" }
        env["WINEMSYNC"] = "1"
        env["WINEESYNC"] = "1"
        if gptk {
            // GPTK/D3DMetal: force builtin DirectX DLLs and don't leak the bundled
            // Wine dylib/datadir paths (those carry DXVK/MoltenVK, which would
            // override D3DMetal and fail under GPTK).
            let gptkBin = "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin"
            env["WINEDLLOVERRIDES"] = "d3d9,d3d10,d3d10core,d3d11,d3d12,d3d12core,dxgi=b"
            env.removeValue(forKey: "DYLD_LIBRARY_PATH")
            env.removeValue(forKey: "WINEDATADIR")
            env["PATH"] = "\(gptkBin):/usr/bin:/bin"
        } else {
            env["WINEDATADIR"] = library.wineDir.appendingPathComponent("share/wine").path
            env["DYLD_LIBRARY_PATH"] = library.wineDir.appendingPathComponent("lib").path
            env["PATH"] = "\(library.wineDir.appendingPathComponent("bin").path):/usr/bin:/bin:/usr/sbin:/sbin"
        }
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let logHandler: (FileHandle) -> Void = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.outputLog += text
                if let log = self?.outputLog, log.count > 50000 {
                    self?.outputLog = String(log.suffix(30000))
                }
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = logHandler
        errPipe.fileHandleForReading.readabilityHandler = logHandler

        proc.terminationHandler = { [weak self] p in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            // Drain what the handlers hadn't consumed — with fast-failing
            // children the final lines are usually the actual error.
            let outTail = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errTail = errPipe.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                for tail in [outTail, errTail] {
                    if let text = String(data: tail, encoding: .utf8), !text.isEmpty {
                        self?.outputLog += text
                    }
                }
                self?.outputLog += "\n[Process exited with code \(p.terminationStatus)]\n"
                self?.isRunning = false
                self?.currentGame = nil
            }
        }

        do {
            try proc.run()
            process = proc
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            isRunning = false
            outputLog = "Failed to launch: \(error.localizedDescription)"
        }
    }

    func stop() {
        process?.terminate()
        // terminate() only reaches the direct child (bash/legendary); the wine
        // processes are grandchildren, and the launch scripts' cleanup traps
        // don't run until wine exits on its own. Shut the wineservers down
        // directly so Stop actually stops the game.
        let gptkServer = "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wineserver"
        let shared = library.supportDir.path
        for (server, prefix) in [
            (library.wineDir.appendingPathComponent("bin/wineserver").path, shared),
            (gptkServer, shared + "-gptk"),
        ] {
            guard FileManager.default.isExecutableFile(atPath: server) else { continue }
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: server)
            kill.arguments = ["-k"]
            var env = ProcessInfo.processInfo.environment
            env["WINEPREFIX"] = prefix
            kill.environment = env
            kill.standardOutput = FileHandle.nullDevice
            kill.standardError = FileHandle.nullDevice
            try? kill.run()
        }
    }

    // MARK: - Epic Games via Legendary

    @Published var epicLoggedIn = false
    @Published var epicUsername: String = ""
    @Published var epicLoginInProgress = false
    @Published var epicInstallProgress: String = ""
    @Published var epicInstalling = false

    @Published var epicLoginError: String = ""

    func checkEpicLogin() {
        DispatchQueue.global().async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: legendaryPath)
            proc.arguments = ["status"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            do {
                try proc.run()
            } catch {
                // legendary isn't installed — bail before touching the pipe, or
                // readDataToEndOfFile() would block forever (no child ever attached).
                DispatchQueue.main.async {
                    self?.epicLoggedIn = false
                    self?.epicUsername = ""
                }
                return
            }
            let outData = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let output = String(data: outData, encoding: .utf8) ?? ""

            DispatchQueue.main.async {
                // Legendary outputs "Epic account: <username>" when logged in
                if output.contains("Epic account:") && !output.contains("<not logged in>") {
                    self?.epicLoggedIn = true
                    // Extract username from "Epic account: MellowLove_"
                    for line in output.split(separator: "\n") {
                        let l = String(line)
                        if l.contains("Epic account:") {
                            let parts = l.split(separator: ":", maxSplits: 1)
                            if parts.count >= 2 {
                                self?.epicUsername = parts[1].trimmingCharacters(in: .whitespaces)
                            }
                            break
                        }
                    }
                } else {
                    self?.epicLoggedIn = false
                    self?.epicUsername = ""
                }
            }
        }
    }

    func epicOpenLoginPage() {
        let url = URL(string: "https://legendary.gl/epiclogin")!
        NSWorkspace.shared.open(url)
    }

    func epicLoginWithCode(_ input: String) {
        epicLoginInProgress = true
        epicLoginError = ""

        // Extract authorizationCode from JSON if user pasted the whole thing
        var code = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if code.hasPrefix("{") {
            // Parse JSON to extract authorizationCode
            if let data = code.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let authCode = json["authorizationCode"] as? String {
                code = authCode
            }
        }
        // Strip any surrounding quotes
        code = code.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

        guard !code.isEmpty, code != "null" else {
            epicLoginInProgress = false
            epicLoginError = "No authorization code found. Make sure you're copying the authorizationCode value."
            return
        }

        DispatchQueue.global().async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: legendaryPath)
            proc.arguments = ["auth", "--code", code]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe

            do {
                try proc.run()
            } catch {
                // legendary isn't installed — bail before touching the pipe, or
                // readDataToEndOfFile() would block forever (no child ever attached).
                DispatchQueue.main.async {
                    self?.epicLoginInProgress = false
                    self?.epicLoginError = "legendary is not installed: \(error.localizedDescription)"
                }
                return
            }

            // Read BEFORE waitUntilExit to avoid pipe buffer deadlock
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""

            DispatchQueue.main.async {
                self?.epicLoginInProgress = false
                if proc.terminationStatus == 0 {
                    self?.checkEpicLogin()
                    self?.library.scan()
                } else {
                    self?.epicLoginError = "Login failed: \(output.prefix(200))"
                    self?.checkEpicLogin()
                }
            }
        }
    }

    func epicInstall(appName: String) {
        epicInstalling = true
        epicInstallProgress = "Starting download..."

        let installDir = library.epicDir.path
        // Ensure Epic Games directory exists
        try? FileManager.default.createDirectory(atPath: installDir, withIntermediateDirectories: true)

        DispatchQueue.global().async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: legendaryPath)
            proc.arguments = ["install", appName,
                              "--base-path", installDir,
                              "--platform", "Windows",
                              "-y"]          // auto-confirm; downloads use HTTPS

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            // Read both stdout and stderr for progress
            for pipe in [outPipe, errPipe] {
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                        let l = String(line).trimmingCharacters(in: .whitespaces)
                        if !l.isEmpty {
                            DispatchQueue.main.async {
                                self?.epicInstallProgress = l
                            }
                        }
                    }
                }
            }

            proc.terminationHandler = { [weak self] p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    self?.epicInstalling = false
                    if p.terminationStatus == 0 {
                        self?.epicInstallProgress = "Done!"
                        self?.library.scan()
                    } else {
                        self?.epicInstallProgress = "Install failed (exit \(p.terminationStatus))"
                    }
                }
            }

            do {
                try proc.run()
            } catch {
                // run() threw — terminationHandler won't fire, so clear state and
                // surface the error instead of wedging the install bar forever.
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    self?.epicInstalling = false
                    self?.epicInstallProgress = "Couldn't start install: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Views

struct GameCardView: View {
    let game: Game
    var onLaunch: () -> Void = {}
    var onLaunchNoEAC: () -> Void = {}
    var onLaunchGPTK: () -> Void = {}
    var onInstall: () -> Void = {}

    private var gptkInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Game Porting Toolkit.app")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Cover art
            coverImage
                .frame(height: 160)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .allowsHitTesting(false)

            // Game name
            Text(game.name)
                .font(.headline)
                .lineLimit(2)
                .foregroundColor(game.isInstalled ? .primary : .secondary)
                .allowsHitTesting(false)

            // Source + size
            HStack(spacing: 4) {
                Text(game.source.rawValue)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if game.isInstalled && game.sizeBytes > 0 {
                    Text("· \(game.sizeFormatted)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if !game.isInstalled {
                    Text("· Not installed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .allowsHitTesting(false)

            // Anti-cheat badge
            if game.antiCheat != .none {
                HStack(spacing: 4) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.caption2)
                    Text(game.antiCheat.rawValue)
                        .font(.caption2)
                }
                .foregroundColor(game.hasLinuxEAC ? .orange : .red)
                .allowsHitTesting(false)
            }

            Spacer(minLength: 4)

            // Launch or Install button — must be clickable
            if game.isInstalled {
                if game.antiCheat != .none {
                    // Anti-cheat game: online/multiplayer isn't supported (Vineport
                    // doesn't circumvent anti-cheat). The offline launch runs the
                    // game without its anti-cheat — via Apple's Game Porting Toolkit
                    // (D3DMetal) when installed, which is required for D3D12 titles.
                    Menu {
                        Section("Online play not supported (anti-cheat)") {
                            Button(action: onLaunchNoEAC) {
                                Label(
                                    gptkInstalled
                                        ? "Play Offline — No Anti-Cheat (D3DMetal)"
                                        : "Play Offline — No Anti-Cheat",
                                    systemImage: "play.fill"
                                )
                            }
                            if !gptkInstalled {
                                Text("Install Game Porting Toolkit for D3D12 games (e.g. Elden Ring)")
                            }
                        }
                        Divider()
                        Button(action: onLaunch) {
                            Label("Standard Launch (through store)", systemImage: "arrowshape.turn.up.right")
                        }
                    } label: {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("Launch")
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .menuStyle(.borderedButton)
                    .tint(game.source == .steam ? .blue : .purple)
                } else if game.source == .steam && gptkInstalled {
                    // Default to GPTK/D3DMetal (reliable for D3D11 + D3D12), with
                    // the Steam client launch as an alternative (overlay/achievements).
                    Menu {
                        Button(action: onLaunchGPTK) {
                            Label("Play (D3DMetal)", systemImage: "play.fill")
                        }
                        Button(action: onLaunch) {
                            Label("Launch via Steam", systemImage: "arrowshape.turn.up.right")
                        }
                    } label: {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("Play")
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .menuStyle(.borderedButton)
                    .tint(.blue)
                } else {
                    Button(action: onLaunch) {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("Launch")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(game.source == .steam ? .blue : .purple)
                }
            } else {
                Button(action: onInstall) {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Install")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(game.source == .steam ? .blue : .purple)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }

    @ViewBuilder
    var coverImage: some View {
        if let url = URL(string: game.imageURL), !game.imageURL.isEmpty {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    fallbackCover
                case .empty:
                    ZStack {
                        Color.gray.opacity(0.1)
                        ProgressView()
                    }
                @unknown default:
                    fallbackCover
                }
            }
        } else {
            fallbackCover
        }
    }

    var fallbackCover: some View {
        ZStack {
            (game.source == .steam ? Color.blue : Color.purple).opacity(0.15)
            VStack(spacing: 4) {
                Image(systemName: "gamecontroller.fill")
                    .font(.largeTitle)
                Text(game.source.rawValue)
                    .font(.caption)
            }
            .foregroundColor(game.source == .steam ? .blue : .purple)
        }
    }
}

struct SetupView: View {
    @ObservedObject var processManager: ProcessManager

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 64))
                .foregroundColor(.purple)

            Text("Welcome to Vineport")
                .font(.largeTitle.bold())

            Text("Wine needs to be downloaded before you can play games.\nThis is a one-time setup (~190 MB).")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            if processManager.isSettingUp {
                VStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.linear)
                    Text(processManager.setupProgress)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(width: 300)
            } else {
                if let err = processManager.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                Button(processManager.lastError == nil ? "Download Wine" : "Try Again") {
                    processManager.runSetup()
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct SidebarView: View {
    @Binding var selection: String?
    let steamCount: Int
    let epicCount: Int
    let epicLoggedIn: Bool

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                Label("All Games", systemImage: "gamecontroller.fill")
                    .tag("all")
                Label("Steam (\(steamCount))", systemImage: "cloud.fill")
                    .tag("steam")
                Label {
                    HStack {
                        Text("Epic (\(epicCount))")
                        if !epicLoggedIn {
                            Circle()
                                .fill(.orange)
                                .frame(width: 6, height: 6)
                        }
                    }
                } icon: {
                    Image(systemName: "bolt.fill")
                }
                .tag("epic")
            }

            Section("Stores") {
                Label("Steam Client", systemImage: "server.rack")
                    .tag("launch-steam")
                Label {
                    Text("Epic Games")
                } icon: {
                    Image(systemName: "bolt.circle.fill")
                }
                .tag("epic-store")
            }

            Section("Tools") {
                Label("Anti-Cheat Status", systemImage: "shield.checkered")
                    .tag("anticheat")
            }

            Section("Settings") {
                Label("Wine Config", systemImage: "gearshape")
                    .tag("settings")
            }
        }
        .listStyle(.sidebar)
    }
}

struct GameGridView: View {
    let games: [Game]
    var onLaunch: (Game) -> Void = { _ in }
    var onLaunchNoEAC: (Game) -> Void = { _ in }
    var onLaunchGPTK: (Game) -> Void = { _ in }
    var onInstall: (Game) -> Void = { _ in }

    let columns = [
        GridItem(.adaptive(minimum: 280, maximum: 400), spacing: 12)
    ]

    var sortedGames: [Game] {
        games.sorted { a, b in
            if a.isInstalled != b.isInstalled { return a.isInstalled }
            return a.name.lowercased() < b.name.lowercased()
        }
    }

    var installedCount: Int { games.filter(\.isInstalled).count }

    var body: some View {
        if games.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text("No games found")
                    .font(.title3)
                    .foregroundColor(.secondary)
                Text("Install games through Steam or Epic Games")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(games.count) games · \(installedCount) installed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(sortedGames) { game in
                            let g = game
                            GameCardView(
                                game: g,
                                onLaunch: { onLaunch(g) },
                                onLaunchNoEAC: { onLaunchNoEAC(g) },
                                onLaunchGPTK: { onLaunchGPTK(g) },
                                onInstall: { onInstall(g) }
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

struct AntiCheatView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Anti-Cheat Status")
                    .font(.largeTitle.bold())

                GroupBox("What Vineport Ships") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Clean, unmodified upstream Wine (Staging)", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Label("No anti-cheat circumvention is included", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                    .padding(8)
                }

                GroupBox("EAC / BattlEye Games") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Online play: not supported unless the game ships native Wine/Proton anti-cheat support",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Label("Offline/singleplayer: use \"Play Offline (No Anti-Cheat)\" on the game card",
                              systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Label("Detected anti-cheat shows as a shield badge in the library",
                              systemImage: "shield.lefthalf.filled")
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                }

                GroupBox("Compatibility") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Check ProtonDB for game-specific reports — if a game runs on Linux/Proton, it will likely work here.")
                            .textSelection(.enabled)
                    }
                    .padding(8)
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Epic Login via Local HTTP Server
//
// Opens the login page in the system browser (Safari/Chrome) which passes
// Cloudflare checks. A tiny local HTTP server captures the redirect and
// extracts the authorization code automatically.

import Network

class EpicAuthServer {
    private var listener: NWListener?
    private var port: UInt16 = 0
    var onAuthCode: ((String) -> Void)?
    var onPageBody: ((String) -> Void)?

    func start() -> UInt16 {
        // Pick a random available port
        let params = NWParameters.tcp
        listener = try? NWListener(using: params, on: .any)

        listener?.stateUpdateHandler = { state in
            if case .ready = state, let p = self.listener?.port?.rawValue {
                self.port = p
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: DispatchQueue.global())

        // Wait briefly for port assignment
        Thread.sleep(forTimeInterval: 0.2)
        if let p = listener?.port?.rawValue {
            port = p
        }
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue.global())

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let data = data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            // Parse the HTTP request for the auth code
            var authCode: String? = nil

            // Check if this is a POST with JSON body containing authorizationCode
            if request.contains("authorizationCode") {
                if let bodyStart = request.range(of: "\r\n\r\n") {
                    let body = String(request[bodyStart.upperBound...])
                    if let jsonData = body.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                       let code = json["authorizationCode"] as? String {
                        authCode = code
                    }
                }
            }

            // Check URL query params for code=
            if authCode == nil, let firstLine = request.split(separator: "\r\n").first {
                let parts = firstLine.split(separator: " ")
                if parts.count >= 2 {
                    let path = String(parts[1])
                    if let components = URLComponents(string: path),
                       let code = components.queryItems?.first(where: { $0.name == "code" })?.value {
                        authCode = code
                    }
                }
            }

            // Check for the JSON body that Epic returns (the page body forwarded by JS)
            if authCode == nil, let firstLine = request.split(separator: "\r\n").first,
               String(firstLine).contains("/callback") {
                // Extract body from POST
                if let bodyStart = request.range(of: "\r\n\r\n") {
                    let body = String(request[bodyStart.upperBound...])
                    // URL-decode the body parameter
                    if body.contains("body=") {
                        let bodyParam = body.replacingOccurrences(of: "body=", with: "")
                            .removingPercentEncoding ?? body
                        if let jsonData = bodyParam.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                           let code = json["authorizationCode"] as? String,
                           code != "<null>", !code.isEmpty {
                            authCode = code
                        }
                    }
                }
            }

            // Send response
            let responseBody: String
            if authCode != nil {
                responseBody = """
                <html><body style="font-family:-apple-system,sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#1a1a2e;color:white;">
                <div style="text-align:center">
                <h1 style="font-size:48px">&#127815;</h1>
                <h2>Logged in to Vineport!</h2>
                <p style="color:#888">You can close this tab and return to the app.</p>
                </div></body></html>
                """
            } else {
                responseBody = """
                <html><body style="font-family:-apple-system,sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#1a1a2e;color:white;">
                <div style="text-align:center">
                <h2>Waiting for login...</h2>
                <p style="color:#888">Complete the login on Epic's page.</p>
                </div></body></html>
                """
            }

            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n\(responseBody)"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })

            if let code = authCode {
                DispatchQueue.main.async {
                    self?.onAuthCode?(code)
                }
            }
        }
    }
}

// Monitors the Epic redirect page in the system browser by polling
// a known URL pattern, since we can't inject JS into Safari.
// Instead, we use a smarter approach: open the login URL with a redirect
// that includes our localhost callback, so the browser comes back to us.

class EpicAuthFlow: ObservableObject {
    @Published var isActive = false
    @Published var serverPort: UInt16 = 0

    private var server = EpicAuthServer()
    var onAuthCode: ((String) -> Void)?

    func start() {
        isActive = true

        server.onAuthCode = { [weak self] code in
            DispatchQueue.main.async {
                self?.isActive = false
                self?.server.stop()
                self?.onAuthCode?(code)
            }
        }

        serverPort = server.start()

        // Open Epic login in system browser
        // After login, Epic redirects to their API which returns JSON with the auth code.
        // We open the legendary.gl/epiclogin URL which handles the redirect properly.
        let url = URL(string: "https://legendary.gl/epiclogin")!
        NSWorkspace.shared.open(url)
    }

    func stop() {
        isActive = false
        server.stop()
    }
}

struct EpicStoreView: View {
    @ObservedObject var processManager: ProcessManager
    @State private var installName: String = ""
    @State private var showLoginFlow = false
    @State private var loginCode: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Epic Games")
                    .font(.largeTitle.bold())

                // Login section
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: processManager.epicLoggedIn
                                  ? "checkmark.circle.fill" : "person.circle")
                                .font(.title2)
                                .foregroundColor(processManager.epicLoggedIn ? .green : .secondary)

                            VStack(alignment: .leading) {
                                if processManager.epicLoggedIn {
                                    Text("Logged in as \(processManager.epicUsername)")
                                        .font(.headline)
                                } else {
                                    Text("Not logged in")
                                        .font(.headline)
                                    Text("Log in to access your Epic Games library")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer()

                            if processManager.epicLoginInProgress {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Logging in...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else if !processManager.epicLoggedIn {
                                Button("Log In") {
                                    showLoginFlow = true
                                    processManager.epicOpenLoginPage()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.purple)
                            }
                        }

                        // Login flow: browser opens, user pastes the JSON back
                        if showLoginFlow && !processManager.epicLoggedIn {
                            Divider()
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 6) {
                                    Image(systemName: "safari")
                                        .foregroundColor(.blue)
                                    Text("A login page opened in your browser.")
                                        .font(.callout)
                                }

                                Text("After logging in, you'll see a page with JSON text. Select all the text on that page and paste it here:")
                                    .font(.callout)
                                    .foregroundColor(.secondary)

                                HStack {
                                    TextField("Paste the JSON from the browser here", text: $loginCode)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(.caption, design: .monospaced))

                                    Button("Log In") {
                                        processManager.epicLoginWithCode(loginCode)
                                        showLoginFlow = false
                                        loginCode = ""
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.purple)
                                    .disabled(loginCode.isEmpty)

                                    Button("Cancel") {
                                        showLoginFlow = false
                                        loginCode = ""
                                    }
                                    .buttonStyle(.bordered)
                                }

                                Button("Re-open login page") {
                                    processManager.epicOpenLoginPage()
                                }
                                .font(.caption)
                            }
                            .padding(8)
                            .background(Color.blue.opacity(0.05))
                            .cornerRadius(8)
                        }

                        if !processManager.epicLoginError.isEmpty {
                            Text(processManager.epicLoginError)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                    .padding(4)
                } label: {
                    Label("Account", systemImage: "person.fill")
                }

                // Install game section
                if processManager.epicLoggedIn {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Enter the Epic app name to install a game.")
                                .font(.callout)
                                .foregroundColor(.secondary)

                            Text("Find names with: vineport epic games")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack {
                                TextField("App name (e.g. Sugar for Rocket League)", text: $installName)
                                    .textFieldStyle(.roundedBorder)

                                Button("Install") {
                                    guard !installName.isEmpty else { return }
                                    processManager.epicInstall(appName: installName)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.purple)
                                .disabled(installName.isEmpty || processManager.epicInstalling)
                            }

                            if processManager.epicInstalling {
                                VStack(alignment: .leading, spacing: 4) {
                                    ProgressView()
                                        .progressViewStyle(.linear)
                                    Text(processManager.epicInstallProgress)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .padding(4)
                    } label: {
                        Label("Install Game", systemImage: "arrow.down.circle.fill")
                    }

                    // Quick install buttons for popular games
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Popular Games")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack(spacing: 8) {
                                QuickInstallButton(name: "Rocket League", appName: "Sugar") {
                                    installName = "Sugar"
                                }
                                QuickInstallButton(name: "Fortnite", appName: "Fortnite") {
                                    installName = "Fortnite"
                                }
                                QuickInstallButton(name: "Fall Guys", appName: "Starter") {
                                    installName = "Starter"
                                }
                            }
                        }
                        .padding(4)
                    } label: {
                        Label("Quick Install", systemImage: "star.fill")
                    }
                }
            }
            .padding(20)
        }
        .onAppear {
            processManager.checkEpicLogin()
        }
    }
}

struct QuickInstallButton: View {
    let name: String
    let appName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: "gamecontroller.fill")
                    .font(.title3)
                Text(name)
                    .font(.caption)
            }
            .frame(width: 90, height: 60)
        }
        .buttonStyle(.bordered)
        .tint(.purple)
    }
}

struct RunningGameView: View {
    @ObservedObject var processManager: ProcessManager
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                if processManager.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Running: \(processManager.currentGame?.name ?? "Game")")
                        .font(.headline)
                } else {
                    Image(systemName: "checkmark.circle")
                        .foregroundColor(.secondary)
                    Text("Process ended")
                        .font(.headline)
                }

                Spacer()

                if processManager.isRunning {
                    Button("Stop") {
                        processManager.stop()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                } else {
                    Button("Back to Library") {
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(12)
            .background(.bar)

            Divider()

            // Log output
            ScrollViewReader { proxy in
                ScrollView {
                    Text(processManager.outputLog.isEmpty ? "Starting..." : processManager.outputLog)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                        .id("log-bottom")
                }
                .onChange(of: processManager.outputLog) { _ in
                    proxy.scrollTo("log-bottom", anchor: .bottom)
                }
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var library = GameLibrary()
    @StateObject private var processManager: ProcessManager
    @State private var sidebarSelection: String? = "all"
    @State private var showRunningView = false
    @State private var searchText = ""
    @State private var showSteamInstallHint = false

    init() {
        let lib = GameLibrary()
        _library = StateObject(wrappedValue: lib)
        _processManager = StateObject(wrappedValue: ProcessManager(library: lib))
    }

    var filteredGames: [Game] {
        var games = library.games

        // Filter by source
        switch sidebarSelection {
        case "steam": games = games.filter { $0.source == .steam }
        case "epic": games = games.filter { $0.source == .epic }
        default: break
        }

        // Filter by search
        if !searchText.isEmpty {
            games = games.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
        }

        return games
    }

    var body: some View {
        Group {
            if !library.wineExists && !processManager.isSettingUp {
                SetupView(processManager: processManager)
            } else if processManager.isSettingUp {
                SetupView(processManager: processManager)
            } else {
                NavigationSplitView {
                    SidebarView(
                        selection: $sidebarSelection,
                        steamCount: library.games.filter { $0.source == .steam }.count,
                        epicCount: library.games.filter { $0.source == .epic }.count,
                        epicLoggedIn: processManager.epicLoggedIn
                    )
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
                } detail: {
                    ZStack {
                        if showRunningView {
                            RunningGameView(processManager: processManager, onDismiss: {
                                showRunningView = false
                            })
                        } else if sidebarSelection == "launch-steam" {
                            VStack(spacing: 20) {
                                Image(systemName: "server.rack")
                                    .font(.system(size: 48))
                                    .foregroundColor(.blue)
                                Text("Steam Client")
                                    .font(.title2.bold())
                                Button("Launch Steam") {
                                    showRunningView = true
                                    processManager.launchSteam()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if sidebarSelection == "epic-store" {
                            EpicStoreView(processManager: processManager)
                        } else if sidebarSelection == "anticheat" {
                            AntiCheatView()
                        } else if sidebarSelection == "settings" {
                            VStack(spacing: 16) {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 48))
                                    .foregroundColor(.secondary)
                                Text("Settings")
                                    .font(.title2.bold())

                                GroupBox("Paths") {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text("Wine:")
                                                .foregroundColor(.secondary)
                                            Text(library.wineDir.path)
                                                .textSelection(.enabled)
                                        }
                                        HStack {
                                            Text("Prefix:")
                                                .foregroundColor(.secondary)
                                            Text(library.supportDir.path)
                                                .textSelection(.enabled)
                                        }
                                        HStack {
                                            Text("Project:")
                                                .foregroundColor(.secondary)
                                            Text(library.projectDir.path)
                                                .textSelection(.enabled)
                                        }
                                    }
                                    .font(.system(.caption, design: .monospaced))
                                    .padding(4)
                                }
                                .frame(maxWidth: 500)

                                Button("Rescan Games") {
                                    library.scan()
                                }
                                .buttonStyle(.bordered)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            GameGridView(
                                games: filteredGames,
                                onLaunch: { game in
                                    showRunningView = true
                                    processManager.launchGame(game)
                                },
                                onLaunchNoEAC: { game in
                                    showRunningView = true
                                    processManager.launchGame(game, mode: .noEAC)
                                },
                                onLaunchGPTK: { game in
                                    showRunningView = true
                                    processManager.launchGame(game, mode: .gptk)
                                },
                                onInstall: { game in
                                    if game.source == .epic {
                                        processManager.epicInstall(appName: game.id)
                                    } else {
                                        // Steam installs go through the Steam client
                                        showSteamInstallHint = true
                                    }
                                }
                            )
                        }
                    }
                    .searchable(text: $searchText, prompt: "Search games")
                    .alert("Install through Steam", isPresented: $showSteamInstallHint) {
                        Button("OK", role: .cancel) { }
                    } message: {
                        Text("This game isn't installed yet. Install it through the Steam client, then use \"Rescan Games\" in Settings to pick it up.")
                    }
                    .safeAreaInset(edge: .bottom) {
                        if processManager.epicInstalling {
                            HStack(spacing: 12) {
                                ProgressView()
                                    .controlSize(.small)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Installing...")
                                        .font(.callout.bold())
                                    Text(processManager.epicInstallProgress)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(12)
                            .background(.bar)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            library.scan()
            processManager.checkEpicLogin()
        }
    }
}

// MARK: - App Entry Point

@main
struct VineportApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 600)
    }
}
