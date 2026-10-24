/// Session and all-time counters for one host, with each ping's outcome booked against the counters
/// its send was booked against.
///
/// A reply or a loss only counts when the ping's send counted, and only in a counter that has not
/// been reset since: resetting with pings in flight can no longer push losses above 100 %, and
/// pings sent while down (not counted, like the original) do not add replies either.
public struct PingLedger: Equatable, Sendable {
    private struct Booking: Equatable, Sendable {
        var session: Int?
        var site: Int?
    }

    public private(set) var session = StatCounter()
    public private(set) var site = StatCounter()
    private var sessionEpoch = 0
    private var siteEpoch = 0
    private var bookings: [UInt64: Booking] = [:]

    public init(site: StatCounter = StatCounter()) {
        self.site = site
    }

    public mutating func sent(_ id: UInt64, counted: Bool) {
        guard counted else { return }
        session.addPingSent()
        site.addPingSent()
        bookings[id] = Booking(session: sessionEpoch, site: siteEpoch)
    }

    /// A reply slower than the timeout counts as a loss (it may arrive before housekeeping marks it lost).
    public mutating func replied(_ id: UInt64, ms: Double, withinTimeout: Bool) {
        guard withinTimeout else {
            lost(id)
            return
        }
        guard let booking = bookings.removeValue(forKey: id) else { return }
        if booking.session == sessionEpoch {
            session.addPingResponse(ms: ms)
        }
        if booking.site == siteEpoch {
            site.addPingResponse(ms: ms)
        }
    }

    public mutating func lost(_ id: UInt64) {
        guard let booking = bookings.removeValue(forKey: id) else { return }
        if booking.session == sessionEpoch {
            session.addPingTimeout()
        }
        if booking.site == siteEpoch {
            site.addPingTimeout()
        }
    }

    public mutating func resetSession() {
        session = StatCounter()
        sessionEpoch += 1
    }

    /// Starts all-time counting afresh, or from a host's saved counters.
    public mutating func resetSite(to counter: StatCounter = StatCounter()) {
        site = counter
        siteEpoch += 1
    }

    /// Drops bookings of pings that are no longer tracked.
    public mutating func retain(_ ids: Set<UInt64>) {
        bookings = bookings.filter { ids.contains($0.key) }
    }
}
