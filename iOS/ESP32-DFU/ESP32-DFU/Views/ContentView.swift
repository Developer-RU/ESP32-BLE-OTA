import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var manager: DFUSessionManager
    @AppStorage("app.language") private var appLanguage = AppLanguage.system.rawValue
    @State private var showDeviceSheet = false
    @State private var showFileImporter = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundGradientView()

                ScrollView {
                    VStack(spacing: 16) {
                        headerCard
                        selectionCard
                        progressCard
                        StageTimelineView(currentStage: manager.currentStage)
                    }
                    .padding(16)
                }
            }
            .navigationTitle(L("app.title"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title3)
                    }
                    .tint(.white)
                }
            }
            .sheet(isPresented: $showDeviceSheet) {
                DevicePickerView()
                    .environmentObject(manager)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(manager)
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    manager.selectFirmware(url: url)
                }
            }
            .onAppear {
                manager.startScan()
            }
            .onDisappear {
                manager.stopScan()
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("header.title"), systemImage: "bolt.badge.shield.checkmark")
                .font(.headline)
                .foregroundStyle(.white)

            Text(manager.stageMessage)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))

            HStack {
                statusTag(title: manager.scanner.isScanning ? L("status.scan_on") : L("status.scan_off"), icon: "dot.radiowaves.left.and.right")
                statusTag(title: manager.isRunning ? L("status.dfu_running") : L("status.idle"), icon: "waveform.path.ecg")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var selectionCard: some View {
        VStack(spacing: 12) {
            actionRow(
                title: manager.selectedDevice?.displayName ?? L("device.not_selected"),
                subtitle: L("device.subtitle"),
                icon: "antenna.radiowaves.left.and.right",
                buttonTitle: L("button.devices")
            ) {
                showDeviceSheet = true
            }

            actionRow(
                title: manager.selectedFirmwareURL?.lastPathComponent ?? L("firmware.not_selected"),
                subtitle: L("firmware.subtitle"),
                icon: "doc.badge.arrow.up",
                buttonTitle: L("button.file")
            ) {
                showFileImporter = true
            }

            HStack(spacing: 12) {
                Button(L("button.start_dfu")) {
                    manager.startDFU()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(manager.selectedDevice == nil || manager.selectedFirmwareURL == nil || manager.isRunning)

                Button(L("button.cancel")) {
                    manager.cancelDFU()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!manager.isRunning)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(manager.currentStage.title, systemImage: manager.currentStage.icon)
                    .font(.headline)
                    .foregroundStyle(Color.black.opacity(0.88))
                Spacer()
                Text("\(Int(manager.progress * 100))%")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.black.opacity(0.82))
            }

            ProgressView(value: manager.progress)
                .tint(.mint)

            Text(manager.currentStage.details)
                .font(.footnote)
                .foregroundStyle(Color.black.opacity(0.65))
        }
        .padding(16)
        .background(Color.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func actionRow(title: String, subtitle: String, icon: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.cyan)
                .frame(width: 38, height: 38)
                .background(Color.cyan.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
        }
    }

    private func statusTag(title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color.white.opacity(0.2), in: Capsule())
    }
}

private struct BackgroundGradientView: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.03, green: 0.11, blue: 0.23), Color(red: 0.00, green: 0.44, blue: 0.63), Color(red: 0.09, green: 0.52, blue: 0.45)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Circle()
                .fill(Color.white.opacity(0.16))
                .frame(width: 220)
                .blur(radius: 30)
                .offset(x: 120, y: -220)
        }
        .overlay {
            Circle()
                .fill(Color.cyan.opacity(0.22))
                .frame(width: 280)
                .blur(radius: 34)
                .offset(x: -110, y: 240)
        }
        .ignoresSafeArea()
    }
}
