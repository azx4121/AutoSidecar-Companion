/// Video can be paused by the client as soon as it receives our hello,
/// before the host finishes setting up the session on its video queue.
public struct HostVideoActivity: Sendable {
    public enum Event: Sendable { case sessionReady, clientActive(Bool) }
    public enum Action: Equatable, Sendable { case wait, start, pause, resendConfiguration }

    private var ready = false
    private var active = true

    public init() {}

    public mutating func receive(_ event: Event, hasPipeline: Bool) -> Action {
        switch event {
        case .sessionReady: ready = true
        case .clientActive(let value): active = value
        }
        guard ready else { return .wait }
        guard active else { return .pause }
        return hasPipeline ? .resendConfiguration : .start
    }
}
