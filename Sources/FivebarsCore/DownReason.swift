/// Why the connection is shown as down, for the UI to word.
public enum DownReason: Equatable, Sendable {
    case hostNotFound
    case noNetwork
    case noReplies
    case socketError(String)

    /// No usable network path wins; otherwise the pinger's last start error; otherwise silence.
    public init(startError: PingError?, pathSatisfied: Bool) {
        if !pathSatisfied {
            self = .noNetwork
            return
        }
        switch startError {
        case .resolution?: self = .hostNotFound
        case .socket(let detail)?: self = .socketError(detail)
        case nil: self = .noReplies
        }
    }
}
