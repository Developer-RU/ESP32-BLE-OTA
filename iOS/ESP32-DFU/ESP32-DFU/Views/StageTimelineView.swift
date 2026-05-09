import SwiftUI

struct StageTimelineView: View {
    @AppStorage("app.language") private var appLanguage = AppLanguage.system.rawValue
    let currentStage: DFUStage

    private let track: [DFUStage] = [.scanning, .connecting, .bootloaderUpload, .initPacket, .firmwareUpload, .validating, .activating, .completed]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("timeline.title"))
                .font(.headline)
                .foregroundStyle(.white.opacity(0.95))

            ForEach(track) { stage in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: stage.icon)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(color(for: stage))
                        .frame(width: 28, height: 28)
                        .background(color(for: stage).opacity(0.16), in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(stage.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.95))
                        Text(stage.details)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.72))
                    }

                    Spacer()
                }
                .padding(8)
                .background(Color.white.opacity(stage == currentStage ? 0.17 : 0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .id(appLanguage)
        .padding(16)
        .background(Color.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func color(for stage: DFUStage) -> Color {
        if stage == currentStage {
            return .mint
        }
        if stage.rawValue == DFUStage.completed.rawValue && currentStage == .completed {
            return .green
        }
        if currentStage == .failed {
            return .red
        }
        return .gray
    }
}
