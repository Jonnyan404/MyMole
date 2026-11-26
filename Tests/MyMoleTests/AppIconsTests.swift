import AppKit
import SynchronizationCompat
import Testing

@testable import MyMole

/// App icons are made off the main thread, once per path, and kept within a limit.
@MainActor
@Suite struct AppIconsTests {
    private final class Made: Sendable {
        let count = Atomic<Int>(0)
        let onMain = Atomic<Bool>(false)
    }

    private static func stub(_ made: Made) -> @Sendable (String) -> NSImage {
        { _ in
            made.count.add(1, ordering: .relaxed)
            if Thread.isMainThread { made.onMain.store(true, ordering: .relaxed) }
            return NSImage(size: NSSize(width: 64, height: 64))
        }
    }

    @Test func anIconIsMadeOnceOffTheMainThreadAndThenThereAtOnce() async {
        let icons = AppIcons()
        let made = Made()
        let path = "/synthetic/Canvas.app"
        #expect(icons.cached(path) == nil)
        async let first = icons.prepared(path, make: Self.stub(made))
        async let second = icons.prepared(path, make: Self.stub(made))
        let images = await (first, second)
        #expect(images.0 === images.1 && icons.cached(path) === images.0)
        #expect(made.count.load(ordering: .relaxed) == 1 && !made.onMain.load(ordering: .relaxed))
        // Asked again, nothing is made.
        #expect(await icons.prepared(path, make: Self.stub(made)) === images.0)
        #expect(made.count.load(ordering: .relaxed) == 1)
        // Let go, it's made again when next shown.
        icons.release()
        #expect(icons.cached(path) == nil && icons.count == 0)
        _ = await icons.prepared(path, make: Self.stub(made))
        #expect(made.count.load(ordering: .relaxed) == 2)
    }

    @Test func theOldestIconsGoPastTheLimit() async {
        let icons = AppIcons()
        icons.limit = 3
        let made = Made()
        for i in 0..<5 { _ = await icons.prepared("/synthetic/App\(i).app", make: Self.stub(made)) }
        #expect(icons.count == 3)
        #expect(icons.cached("/synthetic/App0.app") == nil && icons.cached("/synthetic/App4.app") != nil)
    }

    @Test func theBitmapIsTheSizeTheLargestIconIsShownAt() {
        // Whatever stands at the path, a missing app included, an icon comes back.
        let image = AppIcons.render("/synthetic/Missing.app")
        #expect(image.size == NSSize(width: AppIcons.pixels / 2, height: AppIcons.pixels / 2))
        #expect(image.representations.first?.pixelsWide == AppIcons.pixels)
    }

    /// An icon in an extended range, which no bitmap of 8 bits a channel
    /// holds, is drawn in sRGB rather than handed back as it is.
    @Test func anIconInAnExtendedRangeIsDrawnInSRGB() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.extendedSRGB))
        let wide = try #require(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                              | CGBitmapInfo.byteOrder16Little.rawValue))
        wide.setFillColor(red: 1.2, green: 0.2, blue: 0.2, alpha: 1)
        wide.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let source = try #require(wide.makeImage())
        let image = AppIcons.render(icon: NSImage(cgImage: source, size: NSSize(width: 32, height: 32)))
        #expect(image.representations.first?.pixelsWide == AppIcons.pixels)
        let drawn = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(drawn.colorSpace?.name == CGColorSpace.sRGB)
    }

    /// An icon that gives no bitmap of its own is drawn into one.
    @Test func anIconWithoutABitmapIsDrawnIntoOne() {
        let drawn = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        #expect(AppIcons.render(icon: drawn).representations.first?.pixelsWide == AppIcons.pixels)
    }
}
