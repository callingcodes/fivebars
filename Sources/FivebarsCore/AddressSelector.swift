/// Picks which of a host's resolved addresses to ping.
///
/// Starts with the resolver's first choice. Moves on to the next address when a send fails, or
/// when the current address has left a ping unanswered for `deadline` seconds (a response deadline,
/// not a count of sends, so a slow but working address is kept). A reply is credited to the
/// address the ping was sent to: if that is not the current one, pinging returns to it.
public struct AddressSelector: Equatable, Sendable {
    public let count: Int
    public let deadline: Double
    public private(set) var index = 0
    /// When the oldest ping still unanswered by the current address was sent.
    private var waitingSince: Double?

    public init(count: Int, deadline: Double = 4) {
        self.count = count
        self.deadline = deadline
    }

    /// Records a ping sent to the current address at `now` (monotonic seconds).
    /// Returns true when the next ping should go elsewhere.
    public mutating func sent(at now: Double) -> Bool {
        let since = waitingSince ?? now
        waitingSince = since
        return now - since >= deadline && rotate(to: (index + 1) % max(count, 1))
    }

    /// Records a send that failed outright (no route, address family unusable...).
    public mutating func sendFailed() -> Bool {
        rotate(to: (index + 1) % max(count, 1))
    }

    /// Records a reply from address `answered`. Returns true when that switched the current address.
    public mutating func replied(from answered: Int) -> Bool {
        if answered == index {
            waitingSince = nil
            return false
        }
        return answered >= 0 && answered < count && rotate(to: answered)
    }

    private mutating func rotate(to next: Int) -> Bool {
        waitingSince = nil
        guard count > 1, next != index else { return false }
        index = next
        return true
    }
}
