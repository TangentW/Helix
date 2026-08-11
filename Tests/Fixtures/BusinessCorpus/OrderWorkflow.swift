private enum OrderDecision {
    case accepted(Int)
    case retry(Int)
    case blocked
}

@inline(never)
public func orderDecision(_ attempts: Int, responseCode: Int?) -> String {
    let decision: OrderDecision
    if let code = responseCode, code == 200 {
        decision = .accepted(code)
    } else if attempts < 3 {
        decision = .retry(attempts + 1)
    } else {
        decision = .blocked
    }

    switch decision {
    case let .accepted(code):
        return "accepted:\(code)"
    case let .retry(next):
        return "retry:\(next)"
    case .blocked:
        return "blocked"
    }
}
