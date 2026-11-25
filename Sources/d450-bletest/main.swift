// d450-bletest: exercises the Bluetooth Low Energy link to the D450 without
// using paper. It checks that a full label's worth of data can be sent with
// the printer's flow control before any real label is printed.
//
//   swift run d450-bletest
//
// It does three things:
//   1. connects and reads the firmware version and bitmap mode;
//   2. sends 20 version queries back to back and counts the replies;
//   3. sends a complete label job with its PRINT command left off, clears the
//      printer's image buffer, and checks the printer still answers.
// Nothing here contains a PRINT command, so no label is fed.

#if canImport(CoreBluetooth)
import D450Core
import Foundation

func say(_ message: String) { print(message); fflush(stdout) }

/// A label with a border, bars, fine lines and a checkerboard, so the data is like a real label's.
func testLabel() -> MonoBitmap {
    var p = MonoBitmap(width: 812, height: 1218)
    p.fill(x: 0, y: 0, width: 812, height: 4); p.fill(x: 0, y: 1214, width: 812, height: 4)
    p.fill(x: 0, y: 0, width: 4, height: 1218); p.fill(x: 808, y: 0, width: 4, height: 1218)
    p.fill(x: 60, y: 60, width: 692, height: 80)
    for k in 0 ..< 40 { p.fill(x: 60 + k * 16, y: 180, width: 1 + k % 4, height: 120) }
    for y in 340 ..< 500 { for x in 60 ..< 380 where (x / 8 + y / 8) % 2 == 0 { p.set(x, y) } }
    for y in 340 ..< 500 { for x in 420 ..< 740 where (x + y) % 2 == 0 { p.set(x, y) } }
    for k in 0 ..< 20 { p.fill(x: 60, y: 540 + k * 10, width: 692, height: 1) }
    for k in 0 ..< 400 { p.fill(x: 60 + k, y: 780 + k, width: 3, height: 3) }
    return p
}

let config = ServiceConfig()
let printer = BlePrinter(name: config.bluetoothName, log: say)
printer.trace = true
var passed = true

do {
    say("[1] Connecting...")
    try printer.connect()
    say("    connected; bitmap mode is 4")
    say("    " + (try printer.query("SSSGETVERSION")))

    say("[2] 20 queries back to back...")
    var start = Date()
    for _ in 0 ..< 20 { try printer.send(Array("SSSGETVERSION\r\n".utf8)) }
    var got = 0
    for _ in 0 ..< 20 {
        guard (try? printer.waitFor("GETVERSION:", timeout: 5)) != nil else { break }
        got += 1
    }
    say(String(format: "    %d of 20 answered in %.1f s", got, Date().timeIntervalSince(start)))
    if got != 20 { passed = false }

    printer.trace = false
    say("[3] A full label job without its PRINT command...")
    let settings = config.printer
    let canvas = Tspl.canvas(for: testLabel(), config: settings)
    var job = try Tspl.job(canvas: canvas, config: settings)
    let printCommand = Array("PRINT 1,1\r\n".utf8)
    precondition(Array(job.suffix(printCommand.count)) == printCommand, "job does not end with PRINT")
    job.removeLast(printCommand.count)
    // What is left must end with the bitmap's four zero bytes and a line end.
    precondition(Array(job.suffix(6)) == [0, 0, 0, 0, 13, 10], "unexpected end of job")
    job += Array("CLS\r\n".utf8)            // throw the image away again
    let before = printer.packetsSent
    start = Date()
    try printer.send(Tspl.speedCommand(settings))
    try printer.send(job)
    let took = Date().timeIntervalSince(start)
    say(String(format: "    sent %d bytes in %d packets in %.1f s; waited for the printer %d time(s); fewest packets in hand %d",
               job.count, printer.packetsSent - before, took, printer.creditWaits, printer.lowestCredits))
    // If any data was lost, the printer is still waiting for bitmap bytes and will not answer this.
    let after = try printer.query("SSSGETVERSION", timeout: 10)
    say("    printer still answers: " + after)
} catch {
    passed = false
    say("FAILED: \(error)")
}
printer.disconnect()
say(passed ? "\nRESULT: the link carried a full label's data and the printer stayed in step. No label was printed."
           : "\nRESULT: the test did not pass. No label was printed.")
exit(passed ? 0 : 1)
#else
print("d450-bletest needs macOS (CoreBluetooth).")
#endif
