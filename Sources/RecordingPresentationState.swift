import Foundation

// Window transitions follow successful capture, never the permission/preparation phase.
struct RecordingPresentationState {
    enum Effect: Equatable { case compact, expanded }
    private(set) var sessionID: String?

    mutating func update(id: String?, starting: Bool, stopping: Bool, recording: Bool) -> Effect? {
        if sessionID != nil, id == nil {
            sessionID = nil
            return .expanded
        }
        if let id, id != sessionID, !starting, !stopping, recording {
            sessionID = id
            return .compact
        }
        return nil
    }
}
