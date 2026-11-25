// d450-blescan: listens for Bluetooth Low Energy advertisements for 12 seconds
// and reports whether the D450 is among them. It connects to nothing and
// uses no paper.
//
//   swift run d450-blescan
//
// Labelife's BLE code uses service FF00, so devices advertising that service
// are listed too. Other nearby devices are only counted, not named.

#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

final class Scanner: NSObject, CBCentralManagerDelegate {
    var central: CBCentralManager!
    var seen = Set<UUID>()
    var matches = 0
    var stateNote = "no state reported"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            stateNote = "on"
            central.scanForPeripherals(withServices: nil, options: nil)
        case .poweredOff: stateNote = "Bluetooth is switched off"
        case .unauthorized: stateNote = "this program is not allowed to use Bluetooth (System Settings > Privacy & Security > Bluetooth)"
        case .unsupported: stateNote = "Bluetooth Low Energy is not supported on this Mac"
        default: stateNote = "not ready"
        }
        print("Bluetooth state: \(stateNote)")
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !seen.contains(peripheral.identifier) else { return }
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertised ?? ""
        let services = ((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []).map { $0.uuidString }
        let upper = name.uppercased()
        let likely = upper.contains("D450") || upper.contains("PHOMEMO") || services.contains("FF00")
        // Unnamed devices may send their name in a later packet, so only named or matching ones are final.
        if name.isEmpty && !likely { return }
        seen.insert(peripheral.identifier)
        if likely {
            matches += 1
            print("  MATCH: name \"\(name)\", signal \(RSSI) dBm, services \(services), connectable \(advertisementData[CBAdvertisementDataIsConnectable] ?? "?")")
        }
    }
}

print("Listening for Bluetooth Low Energy devices for 12 seconds...")
let scanner = Scanner()
RunLoop.main.run(until: Date().addingTimeInterval(12))
scanner.central.stopScan()
print("Named devices heard: \(scanner.seen.count); matching the printer: \(scanner.matches)")
print(scanner.matches > 0 ? "RESULT: the printer advertises over Bluetooth Low Energy."
                          : "RESULT: no Low Energy advertisement from the printer was heard.")
#else
print("d450-blescan needs macOS (CoreBluetooth).")
#endif
