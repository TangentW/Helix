import Foundation
import UIKit
import AVFoundation
import Photos

extension MixedFixture {
    static func progress(_ value: Progress) -> Int64 { value.completedUnitCount }
    @MainActor static func frameworks(_ image: UIImage, _ player: AVPlayer, _ asset: PHAsset) -> Int {
        _ = image
        _ = player
        return asset.pixelWidth
    }
    static func bridged(_ value: FixtureBridgedValue) -> FixtureBridgedValue { value }
    static func counter(_ value: FixtureCounter) -> Int32 { value.value }
    static func fallback(_ value: Int?) -> Int { value ?? { 7 }() }
    @MainActor static func mapped(_ value: UIPencilInteraction.Tap) -> UIPencilInteraction.Tap { value }
    @MainActor static func qualifiedTap(_ value: UIKit.UIPencilInteraction.Tap?) -> UIPencilInteraction.Tap? {
        value ?? { nil }()
    }
}
