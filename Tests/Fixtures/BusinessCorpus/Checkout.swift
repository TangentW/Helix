@inline(never)
public func checkoutTotal(
    _ prices: [Int],
    quantities: [Int],
    coupon: Int?
) -> Int {
    guard prices.count == quantities.count else { return -1 }

    var subtotal = 0
    for index in 0..<prices.count {
        subtotal += prices[index] * quantities[index]
    }

    let discount = coupon ?? 0
    if discount <= 0 { return subtotal }
    if discount >= subtotal { return 0 }
    return subtotal - discount
}
