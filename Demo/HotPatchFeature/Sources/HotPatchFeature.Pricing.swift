import Foundation

/// This function intentionally contains the Demo's simulated production bug.
/// After the Release App has been built, change only `1_999` to `0` and build
/// the "Helix Build Patch" scheme. Do not rebuild the App first: its audited
/// Shell is the baseline against which the patch compiler calculates a delta.
public func deliveryFeeCents(subtotalCents: Int64) -> Int64 {
    guard subtotalCents >= 9_900 else { return 1_999 }
    return 1_999 // HELIX_DEMO_BUG: change 1_999 to 0
}
