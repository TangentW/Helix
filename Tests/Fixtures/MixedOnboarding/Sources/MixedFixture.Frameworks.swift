import Foundation
import UIKit
import AVFoundation
import Photos
import CoreGraphics
import CoreFoundation
#if os(macOS)
import AppKit
#endif

extension MixedFixture {
    enum InputSource { case `import`, manual }
    static func imported(_ source: InputSource) -> Bool {
        switch source {
        case .import: true
        case .manual: false
        }
    }
    static func box(_ page: CGPDFPage, _ box: CGPDFBox) -> CGRect { page.getBoxRect(box) }
    static func metadata(_ context: CGContext, _ info: CFDictionary, _ data: CFData) {
        context.beginPDFPage(info)
        context.addDocumentMetadata(data)
    }
    static let initialized: Int = { 11 }()
    static func first<C: Collection>(_ values: C) -> C.Element? { values.first }
    @MainActor static func firstTap(_ values: [UIKit.UIPencilInteraction.Tap]) -> UIPencilInteraction.Tap? {
        first(values)
    }
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
    static func metric() -> CGFloat { Metrics.computed }
    static func callC(_ callback: @convention(c) (Int32) -> Int32) -> Int32 { callback(1) }
    static func callback() -> Int32 { callC { $0 + 1 } }
    static func generic<T>(_ callback: @escaping (T) -> T, _ value: T) -> T { callback(value) }
    static func adapted() -> Int { generic({ (value: Int) in value + 1 }, 1) }
    static func erased(_ callback: @escaping () -> Int) -> () -> Any { callback }
}

fileprivate extension MixedFixture {
    enum Metrics {
        static let first: CGFloat = 8
        static let second: CGFloat = 9
        static var computed: CGFloat { first + second }
    }
}
