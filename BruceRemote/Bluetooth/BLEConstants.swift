import CoreBluetooth

/// GATT identifiers exposed by the Bruce firmware BLE API.
///
/// Enabled on the device via **Config → Advanced → Toggle BLE API**.
///
/// Two firmware layouts exist in the wild, so the app supports both:
///
/// - **Custom serial service** (current `main`, `src/modules/ble_api/`): a single
///   characteristic used for both directions — write commands to it, subscribe to
///   its notifications for output.
/// - **Nordic UART Service (NUS)**: separate RX (write) and TX (notify)
///   characteristics.
///
/// Bruce disables scan-response and advertises only a truncated name (`Bruc`),
/// often *without* the 128-bit service UUID in the advertisement — so filtering a
/// scan by service UUID can miss it. We scan unfiltered and match by name, then
/// discover whichever service the device actually exposes. Lines end with `\r\n`.
enum BruceBLE {
    // Custom serial service (single characteristic).
    static let serialService = CBUUID(string: "4371EC0B-3D43-49F9-B731-7C72A4A7BB91")
    static let serialCharacteristic = CBUUID(string: "D555ED97-BF2A-4F46-B3EB-D1FCDD7325E9")

    // Nordic UART Service (fallback layout).
    static let nusService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let nusRX = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // write  (app  -> Bruce)
    static let nusTX = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // notify (Bruce -> app)

    static let batteryService = CBUUID(string: "180F")
    static let batteryLevel = CBUUID(string: "2A19")

    /// Services we try to discover after connecting (either serial layout + battery).
    static let servicesToDiscover = [serialService, nusService, batteryService]

    /// The device advertises as `Bruce`/`Bruc` (advertising packet is truncated).
    static let advertisedName = "Bruce"

    /// Does an advertised/peripheral name look like a Bruce device?
    static func matchesName(_ name: String?) -> Bool {
        guard let name = name?.lowercased() else { return false }
        return name.hasPrefix("bruc")
    }
}
