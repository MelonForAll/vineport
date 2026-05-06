import Cocoa
import Foundation

// Native macOS launcher for WineSteam.
// Finds launch-steam.sh relative to the .app bundle, sets up logging,
// and executes it. Shows an alert if the script is missing.
// This is optional — the app bundle uses the shell script "launch" by default.
// Build: swiftc -o WineSteam.app/Contents/MacOS/WineSteamLauncher WineSteamLauncher.swift

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let bundlePath = Bundle.main.bundlePath
let appDir = (bundlePath as NSString).deletingLastPathComponent
let launcherPath = (appDir as NSString).appendingPathComponent("launch-steam.sh")

guard FileManager.default.isExecutableFile(atPath: launcherPath) else {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "launch-steam.sh not found"
    alert.informativeText = "Make sure WineSteam.app is inside the WineSteam folder next to launch-steam.sh."
    alert.runModal()
    exit(1)
}

// Create log directory and file
let logDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/WineSteam")
try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

let formatter = DateFormatter()
formatter.dateFormat = "yyyyMMdd-HHmmss"
let logFile = logDir.appendingPathComponent("winesteam-\(formatter.string(from: Date())).log")

// Launch via bash so output is redirected to the log file
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/bin/bash")
proc.arguments = ["-c", """
    exec > "\(logFile.path)" 2>&1
    echo "=== WineSteam started at $(date) ==="
    exec "\(launcherPath)" "$@"
    """]
proc.currentDirectoryURL = URL(fileURLWithPath: appDir)
proc.standardInput = FileHandle.nullDevice

do {
    try proc.run()
} catch {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "Failed to start"
    alert.informativeText = error.localizedDescription
    alert.runModal()
    exit(1)
}

exit(0)
