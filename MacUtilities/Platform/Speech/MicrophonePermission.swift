import AVFoundation

nonisolated enum MicrophonePermissionState: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
}

@MainActor
protocol MicrophonePermissionChecking {
    var state: MicrophonePermissionState { get }
    func request() async -> MicrophonePermissionState
}

@MainActor
struct MicrophonePermissionClient: MicrophonePermissionChecking {
    var state: MicrophonePermissionState {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: .notDetermined
        case .granted: .granted
        case .denied: .denied
        @unknown default: .denied
        }
    }

    func request() async -> MicrophonePermissionState {
        guard state == .notDetermined else { return state }
        _ = await AVAudioApplication.requestRecordPermission()
        return state
    }
}
