import SwiftUI

struct DevicePickerView: View {
    @EnvironmentObject private var manager: DFUSessionManager
    @AppStorage("app.language") private var appLanguage = AppLanguage.system.rawValue
    @Environment(\.dismiss) private var dismiss

    private let panelBackground = Color(red: 0.12, green: 0.12, blue: 0.15)

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                if manager.scanner.isScanning,
                   let remaining = manager.scanner.scanSecondsRemaining {
                    HStack(spacing: 8) {
                        Image(systemName: "timer")
                        Text(L("picker.scan_timeout", remaining))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color.white.opacity(0.12), in: Capsule())
                    .padding(.horizontal, 16)
                }

                List(manager.scanner.devices) { device in
                    Button {
                        manager.selectDevice(device)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.displayName)
                                    .font(.headline)
                                Text(device.identifier.uuidString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Label("\(device.rssi)", systemImage: "wifi")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(device.rssi > -70 ? .green : .orange)
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.white.opacity(0.08))
                }
            }
            .scrollContentBackground(.hidden)
            .background(panelBackground)
            .listStyle(.insetGrouped)
            .navigationTitle(L("picker.title"))
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .tint(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        manager.scanner.isScanning ? manager.stopScan() : manager.startScan()
                    } label: {
                        Image(systemName: manager.scanner.isScanning ? "stop.fill" : "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .tint(.mint)
                }
            }
        }
    }
}
