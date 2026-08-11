@inline(never)
public func unreadScore(
    _ events: [String],
    weights: [String: Int]
) -> Int {
    var total = 0
    for event in events {
        if event.hasPrefix("unread:") {
            total += weights[event] ?? 1
        }
    }
    return total
}
