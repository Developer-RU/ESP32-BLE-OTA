import Foundation

enum DFUStage: String, CaseIterable, Identifiable {
    case idle
    case scanning
    case connecting
    case bootloaderUpload
    case initPacket
    case firmwareUpload
    case validating
    case activating
    case completed
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .idle: return L("stage.idle.title")
        case .scanning: return L("stage.scanning.title")
        case .connecting: return L("stage.connecting.title")
        case .bootloaderUpload: return L("stage.bootloader.title")
        case .initPacket: return L("stage.init.title")
        case .firmwareUpload: return L("stage.fw.title")
        case .validating: return L("stage.validate.title")
        case .activating: return L("stage.activate.title")
        case .completed: return L("stage.completed.title")
        case .failed: return L("stage.failed.title")
        }
    }

    var details: String {
        switch self {
        case .idle: return L("stage.idle.details")
        case .scanning: return L("stage.scanning.details")
        case .connecting: return L("stage.connecting.details")
        case .bootloaderUpload: return L("stage.bootloader.details")
        case .initPacket: return L("stage.init.details")
        case .firmwareUpload: return L("stage.fw.details")
        case .validating: return L("stage.validate.details")
        case .activating: return L("stage.activate.details")
        case .completed: return L("stage.completed.details")
        case .failed: return L("stage.failed.details")
        }
    }

    var icon: String {
        switch self {
        case .idle: return "dot.scope"
        case .scanning: return "dot.radiowaves.left.and.right"
        case .connecting: return "link"
        case .bootloaderUpload: return "arrow.down.doc"
        case .initPacket: return "shippingbox"
        case .firmwareUpload: return "square.and.arrow.down.on.square"
        case .validating: return "checkmark.shield"
        case .activating: return "bolt.horizontal.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }
}
