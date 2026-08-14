#if os(macOS)
import AppKit
@testable import HelixHubApp
import Testing

enum HubApplicationTests {}

extension HubApplicationTests {
@MainActor
@Suite("Helix Hub brand rendering")
struct Brand {
    @Test("Status item images are visible AppKit template masks")
    func statusItemTemplateMasksAreVisible() throws {
        for disconnected in [false, true] {
            let image = HubApplication.Brand.Mark.statusItemImage(
                disconnected: disconnected
            )
            let mask = try alphaMask(of: image)

            #expect(image.size == NSSize(width: 22, height: 14))
            #expect(image.isTemplate)
            #expect(mask.contains { $0 > 0 })
            #expect(mask.contains(0))
        }
    }

    @Test("Offline status moves the replaceable segment")
    func offlineStatusHasDistinctMask() throws {
        let running = HubApplication.Brand.Mark.statusItemImage(
            disconnected: false
        )
        let offline = HubApplication.Brand.Mark.statusItemImage(
            disconnected: true
        )

        #expect(try alphaMask(of: running) != alphaMask(of: offline))
    }

    private func alphaMask(of image: NSImage) throws -> [UInt8] {
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))

        return (0..<bitmap.pixelsHigh).flatMap { y in
            (0..<bitmap.pixelsWide).map { x in
                let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                return UInt8((alpha * 255).rounded())
            }
        }
    }
}
}
#endif
