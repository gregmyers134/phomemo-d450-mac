// d450-ruler: prints the calibration ruler on one label, or writes it to a PNG.
//
//   swift run -c release d450-ruler                 print it (uses one label)
//   swift run -c release d450-ruler --png <file>    write the image only; prints nothing
//
// The page shows which print-head dots and which rows land on the label. Read
// the numbers at the label's four edges.

import D450Core
import Foundation

func say(_ message: String) { print(message); fflush(stdout) }

let config = ServiceConfig()
let canvas = Ruler.page(width: config.printer.headDots, height: config.printer.labelHeightDots)
let args = Array(CommandLine.arguments.dropFirst())

if args.count == 2 && args[0] == "--png" {
    guard FileManager.default.createFile(atPath: args[1], contents: Data(Png.encode(canvas))) else {
        say("cannot write \(args[1])")
        exit(2)
    }
    say("wrote \(args[1]); nothing was printed")
    exit(0)
}
guard args.isEmpty else {
    say("usage: d450-ruler [--png <file>]")
    exit(2)
}

#if canImport(CoreBluetooth)
let printer = BlePrinter(name: config.bluetoothName, log: say)
do {
    let settings = config.printer
    let job = try Tspl.job(canvas: canvas, config: settings)
    say("Connecting...")
    try printer.connect()
    try printer.send(Tspl.speedCommand(settings))
    try printer.send(job)
    say("Sent \(job.count) bytes, waiting for the printer...")
    _ = try printer.waitFor("PRINTING:DONE", timeout: Double(config.doneTimeoutSeconds))
    say("Printed one ruler label.")
    printer.disconnect()
} catch {
    printer.disconnect()
    say("FAILED: \(error)")
    exit(1)
}
#else
say("Printing needs macOS. Use --png <file> here.")
exit(2)
#endif
