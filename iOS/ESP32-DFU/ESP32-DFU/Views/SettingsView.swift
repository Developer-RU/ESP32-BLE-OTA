import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var manager: DFUSessionManager
    @AppStorage("app.language") private var appLanguage = AppLanguage.system.rawValue
    @Environment(\.dismiss) private var dismiss

    private let panelBackground = Color(red: 0.12, green: 0.12, blue: 0.15)

    var body: some View {
        NavigationStack {
            Form {
                Section(L("settings.section.dfu")) {
                    Stepper(L("settings.prn", manager.settings.packetReceiptNotification), value: $manager.settings.packetReceiptNotification, in: 0...50)
                    Stepper(L("settings.mtu", manager.settings.preferredMTU), value: $manager.settings.preferredMTU, in: 23...247)
                }

                Section(L("settings.section.scan")) {
                    Stepper(
                        L("settings.scan_seconds", manager.settings.scanDurationSeconds),
                        value: $manager.settings.scanDurationSeconds,
                        in: 3...60
                    )
                }

                Section(L("settings.section.behavior")) {
                    Toggle(L("settings.auto_reconnect"), isOn: $manager.settings.autoReconnect)
                    Toggle(L("settings.keep_screen_awake"), isOn: $manager.settings.keepScreenAwake)
                }

                Section(L("settings.section.language")) {
                    Picker(L("settings.language_picker"), selection: $appLanguage) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.pickerTitle).tag(language.rawValue)
                        }
                    }
                    .onChange(of: appLanguage) { _ in
                        manager.refreshLocalization()
                    }
                }

                Section(L("settings.section.info")) {
                    Label(L("settings.profile"), systemImage: "checkmark.seal")
                    Label(L("settings.target"), systemImage: "cpu")
                }
            }
            .scrollContentBackground(.hidden)
            .background(panelBackground)
            .listStyle(.insetGrouped)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .listRowBackground(panelBackground.opacity(0.95))
            .navigationTitle(L("settings.title"))
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
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .tint(.mint)
                }
            }
        }
    }
}
