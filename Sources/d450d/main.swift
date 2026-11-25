// d450d: makes a Phomemo D450 label printer available as a driverless IPP
// printer on this machine.
//
//   d450d [--config <file>] [--port <n>]               print on the D450
//   d450d --service                                    the same, run in the background by launchd
//   d450d --dry-run <dir> [--config <file>] [--port <n>]
//   d450d --print-config
//
// In dry-run mode nothing is sent to the printer. Each label is written to
// <dir> as a PNG, next to the exact bytes that would have been sent.
//
// With --service the log also goes to ~/Library/Logs/D450Mac/d450d.log, and
// if the port is taken (another user of this Mac is already running the
// service) it waits for the port instead of giving up.
//
// Settings are read from --config, or else from
// ~/Library/Application Support/D450Mac/config.json if that file exists.

import D450Core
import Foundation

let home = NSHomeDirectory()
let defaultConfigPath = home + "/Library/Application Support/D450Mac/config.json"
let logPath = home + "/Library/Logs/D450Mac/d450d.log"
var logFile: FileHandle?

/// Opens the log file for appending. A log over 1 MB is moved aside first.
func openLog() {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: (logPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    if let size = (try? fm.attributesOfItem(atPath: logPath))?[.size] as? Int, size > 1 << 20 {
        try? fm.removeItem(atPath: logPath + ".1")
        try? fm.moveItem(atPath: logPath, toPath: logPath + ".1")
    }
    if !fm.fileExists(atPath: logPath) { _ = fm.createFile(atPath: logPath, contents: nil) }
    logFile = FileHandle(forWritingAtPath: logPath)
    logFile?.seekToEndOfFile()
}

func say(_ message: String) {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = logFile == nil ? "HH:mm:ss" : "yyyy-MM-dd HH:mm:ss"
    let line = "\(f.string(from: Date())) \(message)"
    print(line)
    fflush(stdout)
    logFile?.write(Data((line + "\n").utf8))
}

func stop(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    logFile?.write(Data((message + "\n").utf8))
    exit(2)
}

let usage = """
usage: d450d [--config <file>] [--port <n>]
       d450d --service
       d450d --dry-run <dir> [--config <file>] [--port <n>]
       d450d --print-config
"""

var dryRunDir: String?
var configPath: String?
var portOverride: Int?
var asService = false
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let flag = args.removeFirst()
    switch flag {
    case "--print-config":
        print(ServiceConfig().defaultJSON())
        exit(0)
    case "--service": asService = true
    case "--dry-run" where !args.isEmpty: dryRunDir = args.removeFirst()
    case "--config" where !args.isEmpty: configPath = args.removeFirst()
    case "--port" where !args.isEmpty:
        guard let p = Int(args.removeFirst()) else { stop(usage) }
        portOverride = p
    default: stop(usage)
    }
}
if asService { openLog() }

var config = ServiceConfig()
if configPath == nil && FileManager.default.fileExists(atPath: defaultConfigPath) { configPath = defaultConfigPath }
if let path = configPath {
    guard let data = FileManager.default.contents(atPath: path) else { stop("cannot read \(path)") }
    do { config = try ServiceConfig.load(json: data) } catch { stop("\(path): \(error)") }
}
if let p = portOverride { config.port = p }
do { try config.validate() } catch { stop("\(error)") }

func run(_ service: D450Service) -> Never {
    var waiting = false
    while true {
        do {
            try service.start()
            break
        } catch {
            guard asService else { stop("cannot start: \(error)") }
            // Most likely another user of this Mac is running the service and has the port.
            // Print jobs still reach that copy. Take over when the port becomes free.
            if !waiting { say("waiting for port \(config.port): \(error)") }
            waiting = true
            sleep(30)
        }
    }
    while true { sleep(3600) }
}

if let path = configPath { say("settings from \(path)") }
if let dir = dryRunDir {
    do {
        let sink = try DryRunSink(directory: dir, log: say)
        say("d450d starting in dry-run mode; labels go to \(dir)")
        run(D450Service(config: config, sink: sink, firstJobId: sink.highestJobNumber() + 1, log: say))
    } catch {
        stop("cannot start: \(error)")
    }
}

#if canImport(CoreBluetooth)
say("d450d starting; labels print on \"\(config.bluetoothName)\" over Bluetooth Low Energy")
run(D450Service(config: config, sink: BleSink(config: config, log: say), log: say))
#else
stop("Printing needs macOS. Here, run with --dry-run <dir>.\n" + usage)
#endif
