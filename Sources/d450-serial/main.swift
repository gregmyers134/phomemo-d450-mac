// d450-serial: checks that the printer answers through the Bluetooth serial
// port that macOS creates for it (/dev/cu.D450). It uses no paper. It opens
// the port, asks for the firmware version and bitmap mode, prints the replies
// and closes the port.
//
//   swift run d450-serial                  use /dev/cu.D450
//   swift run d450-serial /dev/cu.Other    use another port
//
// Close Labelife on the PC and phone first: the printer accepts one
// Bluetooth connection at a time.

import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

func problem() -> String { String(cString: strerror(errno)) + " (errno \(errno))" }

func show(_ bytes: [UInt8]) -> String {
    let text = String(decoding: bytes, as: UTF8.self)
        .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(text)\"  [" + bytes.map { String(format: "%02X", $0) }.joined(separator: " ") + "]"
}

func seconds(since start: Date) -> String { String(format: "%.1f s", Date().timeIntervalSince(start)) }

/// Waits until the port is readable or writable. False on timeout or error.
func ready(_ fd: Int32, _ events: Int32, milliseconds: Int) -> Bool {
    var p = pollfd(fd: fd, events: Int16(events), revents: 0)
    while true {
        let n = poll(&p, 1, Int32(milliseconds))
        if n < 0 && errno == EINTR { continue }
        return n > 0 && Int32(p.revents) & events != 0
    }
}

/// Reads until `stop` says the reply is complete, the port closes, or time runs out.
func readReply(_ fd: Int32, timeout: Double, until stop: ([UInt8]) -> Bool) -> [UInt8] {
    var out = [UInt8]()
    let end = Date().addingTimeInterval(timeout)
    var chunk = [UInt8](repeating: 0, count: 1024)
    while !stop(out) {
        let left = end.timeIntervalSinceNow
        if left <= 0 || !ready(fd, POLLIN, milliseconds: Int(left * 1000)) { break }
        let n = read(fd, &chunk, chunk.count)
        if n > 0 { out.append(contentsOf: chunk[0 ..< n]) }
        else if n == 0 { break }
        else if errno != EAGAIN && errno != EINTR { break }
    }
    return out
}

func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var sent = 0
    while sent < bytes.count {
        let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + sent, bytes.count - sent) }
        if n > 0 { sent += n; continue }
        if n < 0 && (errno == EAGAIN || errno == EINTR) {
            if !ready(fd, POLLOUT, milliseconds: 5000) { return false }
            continue
        }
        return false
    }
    return true
}

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/dev/cu.D450"
print("Opening \(path) and waiting for macOS to connect (up to 20 seconds)...")
var started = Date()
// A plain open of a Bluetooth serial port returns once macOS has connected to
// the device, or fails. It runs on its own thread so it cannot hang the program.
final class OpenResult { var fd: Int32 = -1; var error: Int32 = 0 }
let result = OpenResult()
let opened = DispatchSemaphore(value: 0)
Thread.detachNewThread {
    result.fd = open(path, O_RDWR | O_NOCTTY)
    result.error = errno
    opened.signal()
}
guard opened.wait(timeout: .now() + 20) == .success else {
    print("FAILED: the port did not open within 20 seconds. macOS could not connect to the printer.")
    exit(1)
}
let fd = result.fd
guard fd >= 0 else {
    errno = result.error
    print("FAILED: could not open the port after \(seconds(since: started)): \(problem())")
    exit(1)
}
print("    open after \(seconds(since: started))")

// Raw mode: bytes pass through unchanged, no echo, no line handling.
var settings = termios()
if tcgetattr(fd, &settings) == 0 {
    cfmakeraw(&settings)
    settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
    cfsetspeed(&settings, speed_t(B115200))
    if tcsetattr(fd, TCSANOW, &settings) != 0 { print("    note: could not set raw mode: \(problem())") }
} else {
    print("    note: could not read port settings: \(problem())")
}

let early = readReply(fd, timeout: 1.0) { _ in false }
if !early.isEmpty { print("    printer sent before any command: \(show(early))") }

var answered = 0
for command in ["SSSGETVERSION", "SSSGETBMAPMODE", "BTVER"] {
    started = Date()
    guard writeAll(fd, Array((command + "\r\n").utf8)) else {
        print("\(command): write failed: \(problem())")
        continue
    }
    // A reply is one line ending in CR LF.
    var reply = readReply(fd, timeout: 6) { $0.suffix(2) == [13, 10] }
    reply += readReply(fd, timeout: 0.3) { _ in false }
    if reply.isEmpty {
        print("\(command): no reply within 6 seconds")
    } else if !reply.contains(UInt8(ascii: ":")) {
        // A real answer has the form NAME:value. Anything else is an echo or noise.
        print("\(command): got \(show(reply)), which is not an answer")
    } else {
        print("\(command): \(show(reply))  after \(seconds(since: started))")
        answered += 1
    }
}
close(fd)
print(answered > 0 ? "\nRESULT: the printer answers through \(path) (\(answered) of 3 queries answered)."
                   : "\nRESULT: the port opened but the printer did not answer.")
exit(answered > 0 ? 0 : 1)
