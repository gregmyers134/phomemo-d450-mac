// Bluetooth Low Energy link to the D450.
//
// What the printer was seen to do (observed with d450-bleprobe on firmware V2.4.9):
//   service FF00
//     FF02  write               commands and job data go here
//     FF01  notify              the printer's text replies arrive here
//     FF03  notify              flow control messages arrive here
//   FF03 sends [01 n] and [02 lo hi]. They are read here as "n more packets
//   may be sent" and "largest packet is lo + 256 * hi bytes". On connecting
//   the printer sent [01 07] and [02 F4 00] (7 packets, 244 bytes), and
//   [01 01] after one packet had been written.

#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

public enum BleError: Error, CustomStringConvertible {
    case bluetoothUnavailable(String)
    case notFound(String)
    case connectFailed(String)
    case serviceMissing(String)
    case disconnected
    case timeout(String)
    case wrongMode(String)

    public var description: String {
        switch self {
        case .bluetoothUnavailable(let why): return "Bluetooth is not available: \(why)"
        case .notFound(let name): return "no Bluetooth device named \(name) was found; is the printer on, near, and not connected to a phone or PC?"
        case .connectFailed(let why): return "could not connect to the printer: \(why)"
        case .serviceMissing(let what): return "the printer does not offer \(what)"
        case .disconnected: return "the printer disconnected"
        case .timeout(let what): return "timed out waiting for \(what)"
        case .wrongMode(let got): return "the printer reports bitmap mode \(got), not 4; nothing was printed"
        }
    }
}

public final class BlePrinter: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let service = CBUUID(string: "FF00")
    private static let replies = CBUUID(string: "FF01")
    private static let commands = CBUUID(string: "FF02")
    private static let flow = CBUUID(string: "FF03")

    private let name: String
    private let log: (String) -> Void
    /// Log every flow control message and reply, with timings.
    public var trace = false

    /// Bluetooth callbacks arrive on this queue. Callers block on `cond`.
    private let queue = DispatchQueue(label: "d450.bluetooth")
    private let cond = NSCondition()
    private let started = Date()

    // All of the following are read and written with `cond` locked.
    private var central: CBCentralManager?
    private var power = CBManagerState.unknown
    private var peripheral: CBPeripheral?
    private var writer: CBCharacteristic?
    private var listening = Set<CBUUID>()
    private var ready = false
    private var closing = false
    private var failure: BleError?
    private var credits = 0
    private var creditsSeen = false
    private var packetSize = 20
    private var received = [UInt8]()
    private var modeChecked = false

    /// Counters for the test tool.
    public private(set) var packetsSent = 0
    public private(set) var creditWaits = 0
    public private(set) var lowestCredits = Int.max

    public init(name: String, log: @escaping (String) -> Void) {
        self.name = name
        self.log = log
    }

    private func note(_ message: String) {
        if trace { log(String(format: "  +%.3fs ", Date().timeIntervalSince(started)) + message) }
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        "[" + bytes.map { String(format: "%02X", $0) }.joined(separator: " ") + "]"
    }

    /// Waits, with `cond` locked, until `done` is true. Throws on a link failure or when time runs out.
    private func wait(_ seconds: Double, _ what: String, until done: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            if let f = failure { throw f }
            if !cond.wait(until: deadline) {
                if done() { return }
                if let f = failure { throw f }
                throw BleError.timeout(what)
            }
        }
    }

    // MARK: Connecting

    /// Finds the printer, connects, and checks it is in the bitmap mode this program produces.
    public func connect() throws {
        cond.lock()
        if ready && failure == nil {
            cond.unlock()
        } else {
            do {
                try link()
                cond.unlock()
            } catch {
                cond.unlock()
                disconnect()
                throw error
            }
        }
        if !modeChecked {
            do {
                let mode = try query("SSSGETBMAPMODE", timeout: 5)
                guard mode.hasSuffix(":4") else { throw BleError.wrongMode(mode) }
                cond.lock(); modeChecked = true; cond.unlock()
            } catch {
                disconnect()
                throw error
            }
        }
    }

    /// Called with `cond` locked.
    private func link() throws {
        failure = nil
        ready = false
        closing = false
        peripheral = nil
        writer = nil
        listening = []
        credits = 0
        creditsSeen = false
        packetSize = 20
        received = []
        modeChecked = false
        if central == nil { central = CBCentralManager(delegate: self, queue: queue) }
        try wait(8, "Bluetooth to start") { power != .unknown && power != .resetting }
        switch power {
        case .poweredOn: break
        case .poweredOff: throw BleError.bluetoothUnavailable("it is switched off")
        case .unauthorized: throw BleError.bluetoothUnavailable("this program is not allowed to use it (System Settings > Privacy & Security > Bluetooth)")
        default: throw BleError.bluetoothUnavailable("this Mac does not support Bluetooth Low Energy")
        }
        let manager = central
        queue.async { manager?.scanForPeripherals(withServices: nil, options: nil) }
        do {
            try wait(15, "the printer to be found") { peripheral != nil }
        } catch BleError.timeout {
            queue.async { manager?.stopScan() }
            throw BleError.notFound(name)
        }
        try wait(15, "the connection to be set up") { ready }
        try wait(3, "the printer's flow control message") { creditsSeen }
    }

    /// Ends the connection. Safe to call when not connected.
    public func disconnect() {
        cond.lock()
        closing = true
        let p = peripheral
        let manager = central
        ready = false
        cond.unlock()
        if let p = p {
            queue.async { manager?.cancelPeripheralConnection(p) }
            cond.lock()
            let deadline = Date().addingTimeInterval(3)
            while peripheral != nil { if !cond.wait(until: deadline) { break } }
            peripheral = nil
            cond.unlock()
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        cond.lock()
        power = central.state
        cond.broadcast()
        cond.unlock()
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let found = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard found.uppercased().contains(name.uppercased()) else { return }
        cond.lock()
        let first = self.peripheral == nil && !closing
        if first { self.peripheral = peripheral }
        cond.broadcast()
        cond.unlock()
        guard first else { return }
        central.stopScan()
        log("found \"\(found)\", signal \(RSSI) dBm" + (RSSI.intValue < -85 ? " (weak: move the printer closer to the Mac)" : ""))
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        note("connected")
        peripheral.discoverServices([BlePrinter.service])
    }

    private func fail(_ error: BleError) {
        cond.lock()
        if failure == nil { failure = error }
        ready = false
        cond.broadcast()
        cond.unlock()
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail(.connectFailed(error?.localizedDescription ?? "no reason given"))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        note("disconnected" + (error.map { ": \($0.localizedDescription)" } ?? ""))
        cond.lock()
        if !closing && failure == nil { failure = .disconnected }
        ready = false
        self.peripheral = nil
        writer = nil
        cond.broadcast()
        cond.unlock()
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = (peripheral.services ?? []).first(where: { $0.uuid == BlePrinter.service }) else {
            fail(.serviceMissing("service FF00"))
            return
        }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let all = service.characteristics ?? []
        guard let w = all.first(where: { $0.uuid == BlePrinter.commands }),
              let r = all.first(where: { $0.uuid == BlePrinter.replies }),
              let f = all.first(where: { $0.uuid == BlePrinter.flow }) else {
            fail(.serviceMissing("characteristics FF01, FF02 and FF03"))
            return
        }
        cond.lock()
        writer = w
        cond.unlock()
        peripheral.setNotifyValue(true, for: r)
        peripheral.setNotifyValue(true, for: f)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            fail(.connectFailed("could not listen on \(characteristic.uuid.uuidString): \(error.localizedDescription)"))
            return
        }
        cond.lock()
        listening.insert(characteristic.uuid)
        if listening.contains(BlePrinter.replies) && listening.contains(BlePrinter.flow) { ready = true }
        cond.broadcast()
        cond.unlock()
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value, !value.isEmpty else { return }
        let bytes = [UInt8](value)
        cond.lock()
        if characteristic.uuid == BlePrinter.flow {
            if bytes[0] == 0x01 && bytes.count >= 2 {
                credits += Int(bytes[1])
                creditsSeen = true
                note("FF03 \(BlePrinter.hex(bytes))  +\(bytes[1]) packets, \(credits) allowed now")
            } else if bytes[0] == 0x02 && bytes.count >= 3 {
                packetSize = max(1, Int(bytes[1]) | Int(bytes[2]) << 8)
                note("FF03 \(BlePrinter.hex(bytes))  packet size \(packetSize)")
            } else {
                note("FF03 \(BlePrinter.hex(bytes))  (not understood)")
            }
        } else if characteristic.uuid == BlePrinter.replies {
            received += bytes
            let text = String(decoding: bytes, as: UTF8.self)
                .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
            note("FF01 \"\(text)\"")
        }
        cond.broadcast()
        cond.unlock()
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        cond.lock()
        cond.broadcast()
        cond.unlock()
    }

    // MARK: Sending and receiving

    /// Sends bytes to the printer, one packet per permission the printer has granted.
    public func send(_ bytes: [UInt8]) throws {
        var pos = 0
        while pos < bytes.count {
            cond.lock()
            if credits == 0 { creditWaits += 1 }
            do {
                try wait(10, "the printer to accept more data") { credits > 0 }
            } catch {
                cond.unlock()
                throw error
            }
            guard ready, let p = peripheral, let w = writer else {
                cond.unlock()
                throw BleError.disconnected
            }
            credits -= 1
            lowestCredits = min(lowestCredits, credits)
            let size = min(packetSize, p.maximumWriteValueLength(for: .withoutResponse), bytes.count - pos)
            cond.unlock()

            let packet = Data(bytes[pos ..< pos + size])
            // Give the Mac's own send queue up to a second to drain, then write.
            let patience = Date().addingTimeInterval(1)
            while true {
                let wrote = queue.sync { () -> Bool in
                    guard p.canSendWriteWithoutResponse || Date() > patience else { return false }
                    p.writeValue(packet, for: w, type: .withoutResponse)
                    return true
                }
                if wrote { break }
                cond.lock()
                _ = cond.wait(until: Date().addingTimeInterval(0.01))
                cond.unlock()
            }
            pos += size
            cond.lock()
            packetsSent += 1
            cond.unlock()
        }
    }

    /// Waits for a reply line containing `marker` and returns that line. Earlier lines are dropped.
    public func waitFor(_ marker: String, timeout: Double) throws -> String {
        let m = Array(marker.utf8)
        var line = ""
        cond.lock()
        defer { cond.unlock() }
        try wait(timeout, "\"\(marker)\" from the printer") {
            guard received.count >= m.count else { return false }
            var at = -1
            for i in 0 ... received.count - m.count where Array(received[i ..< i + m.count]) == m { at = i; break }
            guard at >= 0 else { return false }
            // The line is complete once its CR LF has arrived.
            var end = -1
            var j = at + m.count
            while j + 1 < received.count { if received[j] == 13 && received[j + 1] == 10 { end = j; break }; j += 1 }
            guard end >= 0 else { return false }
            var start = at
            while start > 0 && received[start - 1] != 10 { start -= 1 }
            line = String(decoding: received[start ..< end], as: UTF8.self)
            received.removeFirst(end + 2)
            return true
        }
        return line
    }

    /// Sends a query such as "SSSGETVERSION" and returns the reply line, such as "SSSGETVERSION:V2.4.9".
    public func query(_ command: String, timeout: Double = 5) throws -> String {
        try send(Array((command + "\r\n").utf8))
        // The first characters of a reply can go missing, so match on the tail of the name.
        return try waitFor(String(command.dropFirst(3)) + ":", timeout: timeout)
    }
}

/// Prints labels on the D450 over Bluetooth Low Energy. The connection is
/// opened for a job and closed a few seconds after the last label, so the
/// printer stays free for other devices the rest of the time.
public final class BleSink: LabelSink {
    private let printer: BlePrinter
    private let doneTimeout: Int
    private let log: (String) -> Void
    private let lock = NSLock()
    private var idle: DispatchWorkItem?
    private static let idleSeconds = 4.0

    public init(config: ServiceConfig, log: @escaping (String) -> Void) {
        self.printer = BlePrinter(name: config.bluetoothName, log: log)
        self.doneTimeout = config.doneTimeoutSeconds
        self.log = log
    }

    public func received(jobId: Int, document: [UInt8], format: RasterFormat) {}

    public func deliver(jobId: Int, label: Int, copies: Int, canvas: MonoBitmap, speed: [UInt8], job: [UInt8]) throws {
        lock.lock()
        idle?.cancel()
        idle = nil
        lock.unlock()
        do {
            try printer.connect()
            try printer.send(speed)
            try printer.send(job)
            log("job \(jobId) label \(label): sent \(speed.count + job.count) bytes, waiting for the printer")
            _ = try printer.waitFor("PRINTING:DONE", timeout: Double(doneTimeout * max(1, copies)))
            log("job \(jobId) label \(label): printed")
        } catch {
            printer.disconnect()
            throw error
        }
        let item = DispatchWorkItem { [printer] in printer.disconnect() }
        lock.lock()
        idle = item
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + BleSink.idleSeconds, execute: item)
    }
}
#endif
