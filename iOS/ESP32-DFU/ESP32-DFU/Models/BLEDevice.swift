import Foundation

struct BLEDevice: Identifiable, Hashable {
    let id = UUID()
    let identifier: UUID
    var name: String
    var rssi: Int

    var displayName: String {
        name.isEmpty ? L("device.unknown") : name
    }
}
