// d450-probe: checks that this Mac can talk to the D450 over Classic Bluetooth.
// It uses no paper. It tries to reach the printer, open its serial port
// service, ask for the firmware version and bitmap mode, and disconnect.
// It reports what happened at each stage.
//
//   swift run d450-probe                      list paired Bluetooth devices
//   swift run d450-probe <address>           connect to that Bluetooth address and query it
//   swift run d450-probe <address> --pair    pair with it first if it is not paired
//
// Close Labelife on the PC and phone first: the printer accepts one
// Bluetooth connection at a time.

#if canImport(IOBluetooth)
import Foundation
import IOBluetooth

let success: IOReturn = 0

func hex(_ r: IOReturn) -> String { "0x" + String(UInt32(bitPattern: r), radix: 16) }

/// Lets the main run loop deliver Bluetooth events until `done` is true or time runs out.
@discardableResult
func wait(_ seconds: Double, until done: () -> Bool = { false }) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return done()
}

func seconds(since start: Date) -> String { String(format: "%.1f s", Date().timeIntervalSince(start)) }

final class Probe: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var received = [UInt8]()
    var closed = false
    var sdpDone = false
    var sdpStatus: IOReturn = 0
    var inquiryDone = false

    @objc(sdpQueryComplete:status:)
    func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        sdpStatus = status
        sdpDone = true
    }

    @objc(rfcommChannelData:data:length:)
    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = dataPointer.assumingMemoryBound(to: UInt8.self)
        received.append(contentsOf: UnsafeBufferPointer(start: bytes, count: dataLength))
    }

    @objc(rfcommChannelClosed:)
    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        closed = true
    }

    var pairDone = false
    var pairStatus: IOReturn = 0

    @objc(devicePairingStarted:)
    func devicePairingStarted(_ sender: Any!) {
        print("    pairing started")
    }

    @objc(devicePairingUserConfirmationRequest:numericValue:)
    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        // The printer has no screen or keypad, so there is nothing to compare the number with.
        print("    the printer asked to confirm code \(numericValue); accepting")
        (sender as? IOBluetoothDevicePair)?.replyUserConfirmation(true)
    }

    @objc(devicePairingFinished:error:)
    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        pairStatus = error
        pairDone = true
    }

    @objc(deviceInquiryComplete:error:aborted:)
    func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        inquiryDone = true
    }
}

func show(_ bytes: [UInt8]) -> String {
    let text = String(decoding: bytes, as: UTF8.self)
        .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(text)\"  [" + bytes.map { String(format: "%02X", $0) }.joined(separator: " ") + "]"
}

/// Serial ports macOS has created. A paired serial-port device can show up here.
func serialPorts() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []).filter { $0.hasPrefix("cu.") }.sorted()
}

var args = Array(CommandLine.arguments.dropFirst())
let pairRequested = args.contains("--pair")
args.removeAll { $0 == "--pair" }

if args.isEmpty {
    let list: [Any]? = IOBluetoothDevice.pairedDevices()
    let devices = (list ?? []).compactMap { $0 as? IOBluetoothDevice }
    print("Paired Bluetooth devices: \(devices.count)")
    for d in devices {
        let name: String? = d.name
        let address: String? = d.addressString
        print("  \(address ?? "?")  \(name ?? "(no name)")  connected: \(d.isConnected())")
    }
    print("Serial ports: \(serialPorts().joined(separator: ", "))")
    print("\nTo test the printer: swift run d450-probe <address>")
    exit(0)
}

let address = args[0].replacingOccurrences(of: ":", with: "-")
let found: IOBluetoothDevice? = IOBluetoothDevice(addressString: address)
guard let device = found else {
    print("FAILED: \(args[0]) is not a valid Bluetooth address.")
    exit(1)
}
let probe = Probe()
let deviceName: String? = device.name
print("Device \(address): name \(deviceName ?? "(not known yet)"), paired: \(device.isPaired()), connected: \(device.isConnected())")
print("Serial ports: \(serialPorts().joined(separator: ", "))")

// 1. Radio link.
print("\n[1] Opening the radio link...")
var started = Date()
let linkResult = device.openConnection()
print("    result \(hex(linkResult)) after \(seconds(since: started)); connected: \(device.isConnected())")

// 2. Ask the device which services it offers.
print("[2] Looking up services...")
started = Date()
let queryStarted = device.performSDPQuery(probe)
if queryStarted != success {
    print("    could not start the lookup (\(hex(queryStarted)))")
} else if wait(15, until: { probe.sdpDone }) {
    print("    lookup finished with status \(hex(probe.sdpStatus)) after \(seconds(since: started))")
} else {
    print("    no completion notice within 15 seconds")
}
let serviceList: [Any]? = device.services
let services = (serviceList ?? []).compactMap { $0 as? IOBluetoothSDPServiceRecord }
print("    services known: \(services.count)")
for s in services {
    let serviceName: String? = s.getServiceName()
    var id: BluetoothRFCOMMChannelID = 0
    let hasChannel = s.getRFCOMMChannelID(&id) == success
    print("      \(serviceName ?? "(unnamed)")" + (hasChannel ? "  RFCOMM channel \(id)" : ""))
}

// 2b. Pair, only when asked with --pair. Pairing is remembered by macOS
// (System Settings > Bluetooth) until the device is removed there.
var pairing: IOBluetoothDevicePair?
if pairRequested && !device.isPaired() {
    print("[2b] Pairing with the printer...")
    started = Date()
    pairing = IOBluetoothDevicePair(device: device)
    pairing?.delegate = probe
    let pairStarted: IOReturn = pairing?.start() ?? -1
    if pairStarted != success {
        print("    could not start pairing (\(hex(pairStarted)))")
    } else if wait(40, until: { probe.pairDone }) {
        print("    pairing finished with status \(hex(probe.pairStatus)) after \(seconds(since: started)); paired: \(device.isPaired())")
    } else {
        print("    pairing did not finish within 40 seconds; paired: \(device.isPaired())")
    }
} else if pairRequested {
    print("[2b] Already paired.")
}

// 3. Channels to try: the Serial Port service's channel if it was found, then 1 to 5.
var candidates = [BluetoothRFCOMMChannelID]()
let serialUUID: IOBluetoothSDPUUID? = IOBluetoothSDPUUID(uuid16: 0x1101)
let serialRecord: IOBluetoothSDPServiceRecord? = device.getServiceRecord(for: serialUUID)
if let record = serialRecord {
    var id: BluetoothRFCOMMChannelID = 0
    if record.getRFCOMMChannelID(&id) == success {
        print("    Serial Port service is on RFCOMM channel \(id)")
        candidates.append(id)
    }
} else {
    print("    Serial Port service not listed; trying channels 1 to 5 directly")
}
for id in 1 ... 5 where !candidates.contains(BluetoothRFCOMMChannelID(id)) { candidates.append(BluetoothRFCOMMChannelID(id)) }

print("[3] Opening a serial channel...")
var channel: IOBluetoothRFCOMMChannel?
for id in candidates {
    started = Date()
    var opened: IOBluetoothRFCOMMChannel?
    let openResult = device.openRFCOMMChannelSync(&opened, withChannelID: id, delegate: probe)
    print("    channel \(id): result \(hex(openResult)) after \(seconds(since: started))")
    if openResult == success, let c = opened {
        channel = c
        break
    }
    // Stop early when the printer cannot be reached at all.
    if !device.isConnected() && linkResult != success && id == candidates[0] { break }
}

var answered = 0
if let channel = channel {
    print("    open. MTU \(channel.getMTU()).")
    wait(0.5)
    if !probe.received.isEmpty {
        print("    printer sent before any command: \(show(probe.received))")
        probe.received.removeAll()
    }
    // 4. Safe queries. None of these feeds paper.
    print("[4] Queries...")
    for command in ["SSSGETVERSION", "SSSGETBMAPMODE", "BTVER"] {
        var bytes = Array((command + "\r\n").utf8)
        let writeResult = channel.writeSync(&bytes, length: UInt16(bytes.count))
        if writeResult != success {
            print("    \(command): write failed (\(hex(writeResult)))")
            continue
        }
        // A reply is one line ending in CR LF.
        wait(5, until: { probe.received.suffix(2) == [13, 10] || probe.closed })
        wait(0.2)
        if probe.received.isEmpty {
            print("    \(command): no reply within 5 seconds")
        } else {
            print("    \(command): \(show(probe.received))")
            answered += 1
        }
        probe.received.removeAll()
        if probe.closed { print("    the printer closed the channel"); break }
    }
    _ = channel.close()
} else {
    // 5. Could not connect: see whether the printer is visible to a Classic Bluetooth search.
    print("[5] No channel opened. Searching for nearby Classic Bluetooth devices (about 10 seconds)...")
    let inquiry: IOBluetoothDeviceInquiry? = IOBluetoothDeviceInquiry(delegate: probe)
    if let inquiry = inquiry {
        inquiry.inquiryLength = 8
        inquiry.updateNewDeviceNames = true
        let startResult = inquiry.start()
        if startResult != success {
            print("    could not start the search (\(hex(startResult)))")
        } else {
            wait(20, until: { probe.inquiryDone })
            _ = inquiry.stop()
            let foundList: [Any]? = inquiry.foundDevices()
            let nearby = (foundList ?? []).compactMap { $0 as? IOBluetoothDevice }
            var printerSeen = false
            for d in nearby {
                let a: String? = d.addressString
                let n: String? = d.name
                if (a ?? "").lowercased() == address.lowercased() || (n ?? "").uppercased().contains("D450") {
                    printerSeen = true
                    print("    found the printer: \(a ?? "?")  \(n ?? "(no name)")")
                }
            }
            print("    devices found: \(nearby.count); printer among them: \(printerSeen)")
        }
    }
}

_ = device.closeConnection()
wait(0.5)
if answered > 0 {
    print("\nRESULT: the Mac can talk to the printer over Classic Bluetooth (\(answered) of 3 queries answered).")
} else if channel != nil {
    print("\nRESULT: a channel opened but the printer did not answer.")
} else {
    print("\nRESULT: could not open a serial channel to the printer.")
}
exit(answered > 0 ? 0 : 1)

#else
print("d450-probe needs macOS (IOBluetooth).")
#endif
