// d450-bleprobe: checks whether the D450 can be reached over Bluetooth Low
// Energy. It uses no paper. It finds the printer, connects, lists its services
// and characteristics, then sends "SSSGETVERSION" to each writable
// characteristic of service FF00 (the one Labelife's BLE code uses) and prints
// anything the printer sends back. It writes to no other service.
//
//   swift run d450-bleprobe

#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

func show(_ bytes: [UInt8]) -> String {
    let text = String(decoding: bytes, as: UTF8.self)
        .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(text)\"  [" + bytes.map { String(format: "%02X", $0) }.joined(separator: " ") + "]"
}

final class BleProbe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var printer: CBPeripheral?
    var finished = false
    var replies = 0
    var pendingServices = 0
    /// Writable characteristics of service FF00, in discovery order.
    var targets = [CBCharacteristic]()
    var serviceOf = [CBUUID: String]()      // characteristic UUID -> service UUID, for the log
    var sawFF00 = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func finish(_ message: String) {
        guard !finished else { return }
        print(message)
        if let p = printer { central.cancelPeripheralConnection(p) }
        finished = true
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            if central.state == .poweredOff { finish("FAILED: Bluetooth is switched off.") }
            if central.state == .unauthorized { finish("FAILED: this program is not allowed to use Bluetooth.") }
            return
        }
        print("[1] Searching for the printer (up to 15 seconds)...")
        central.scanForPeripherals(withServices: nil, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [self] in
            if printer == nil { central.stopScan(); finish("FAILED: no device named D450 was heard.") }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard printer == nil else { return }
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard name.uppercased().contains("D450") else { return }
        printer = peripheral
        central.stopScan()
        print("    found \"\(name)\", signal \(RSSI) dBm")
        print("[2] Connecting...")
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [self] in
            if peripheral.state != .connected { finish("FAILED: could not connect within 15 seconds.") }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("    connected")
        print("[3] Listing services...")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish("FAILED: connection refused: \(error?.localizedDescription ?? "no reason given")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if !finished { finish("The printer disconnected: \(error?.localizedDescription ?? "no reason given")") }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error { finish("FAILED: could not list services: \(error.localizedDescription)"); return }
        let services = peripheral.services ?? []
        pendingServices = services.count
        if services.isEmpty { finish("FAILED: the printer lists no services.") }
        for s in services { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let isFF00 = service.uuid == CBUUID(string: "FF00")
        if isFF00 { sawFF00 = true }
        print("    service \(service.uuid.uuidString)" + (error.map { "  (error: \($0.localizedDescription))" } ?? ""))
        for c in service.characteristics ?? [] {
            var props = [String]()
            if c.properties.contains(.read) { props.append("read") }
            if c.properties.contains(.write) { props.append("write") }
            if c.properties.contains(.writeWithoutResponse) { props.append("write-without-response") }
            if c.properties.contains(.notify) { props.append("notify") }
            if c.properties.contains(.indicate) { props.append("indicate") }
            print("      characteristic \(c.uuid.uuidString): \(props.joined(separator: ", "))")
            serviceOf[c.uuid] = service.uuid.uuidString
            // Listen on FF00 only; other services are left alone.
            if isFF00 && (c.properties.contains(.notify) || c.properties.contains(.indicate)) {
                peripheral.setNotifyValue(true, for: c)
            }
            if isFF00 && (c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse)) {
                targets.append(c)
            }
        }
        pendingServices -= 1
        if pendingServices == 0 {
            // Give the notification subscriptions a moment to take effect.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in query(0) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("    could not listen on \(characteristic.uuid.uuidString): \(error.localizedDescription)")
        } else {
            print("    listening on \(characteristic.uuid.uuidString)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value, !value.isEmpty else { return }
        replies += 1
        print("    from \(characteristic.uuid.uuidString): \(show([UInt8](value)))")
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error { print("    write to \(characteristic.uuid.uuidString) failed: \(error.localizedDescription)") }
    }

    /// Sends the version query to one writable FF00 characteristic, waits, then moves to the next.
    func query(_ index: Int) {
        guard !finished, let p = printer else { return }
        if index == 0 {
            print("[4] Queries...")
            print("    largest write: \(p.maximumWriteValueLength(for: .withoutResponse)) bytes without response, \(p.maximumWriteValueLength(for: .withResponse)) with response")
            if !sawFF00 { finish("RESULT: connected over Bluetooth Low Energy, but the printer has no FF00 service. Nothing was sent."); return }
            if targets.isEmpty { finish("RESULT: service FF00 has no writable characteristic. Nothing was sent."); return }
        }
        guard index < targets.count else {
            finish(replies > 0 ? "\nRESULT: the printer answers over Bluetooth Low Energy (\(replies) message(s) received)."
                               : "\nRESULT: connected and sent the query, but the printer sent nothing back.")
            return
        }
        let c = targets[index]
        let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        print("    sending SSSGETVERSION to \(c.uuid.uuidString) (\(type == .withoutResponse ? "without" : "with") response)")
        p.writeValue(Data("SSSGETVERSION\r\n".utf8), for: c, type: type)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in query(index + 1) }
    }
}

let probe = BleProbe()
let deadline = Date().addingTimeInterval(75)
while !probe.finished && Date() < deadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
}
if !probe.finished { print("Stopped after 75 seconds without finishing.") }
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
exit(probe.replies > 0 ? 0 : 1)
#else
print("d450-bleprobe needs macOS (CoreBluetooth).")
#endif
