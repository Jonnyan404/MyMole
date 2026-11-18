import AppKit
import SwiftUI

/// App icons as small bitmaps, made off the main thread and kept by path.
/// Asking Launch Services for an icon and drawing it for the first time
/// decodes it, some 10 ms an icon and far more for a few: done where the
/// grid draws, a screenful of apps held the window still while it appeared
/// and every new row did while it scrolled. A bitmap at the size shown
/// draws at once, and takes far less memory than the icon's every size.
@MainActor
final class AppIcons {
    /// The app's icons; a test keeps a store of its own.
    static let shared = AppIcons()

    private var cache: [String: NSImage] = [:]
    /// In the order they were made, so the oldest go first.
    private var order: [String] = []
    private var making: [String: Task<Prepared, Never>] = [:]
    /// More icons than any app list shows at once; Settings → Responsiveness sets it.
    var limit = 300
    /// The largest an icon is shown, at a Retina display's two pixels a point.
    nonisolated static let pixels = 128

    /// Drawn until an icon is ready: nothing, so no stand-in flashes by.
    static let placeholder = NSImage(size: NSSize(width: pixels / 2, height: pixels / 2))

    /// The icon if it has been made; asking never reads the disk.
    func cached(_ path: String) -> NSImage? { cache[path] }

    /// The icon of the app at `path`, made once however many views ask.
    func prepared(_ path: String, make: @escaping @Sendable (String) -> NSImage = AppIcons.render) async -> NSImage {
        if let image = cache[path] { return image }
        if let running = making[path] { return await running.value.image }
        let job = Task.detached(priority: .userInitiated) { Prepared(image: make(path)) }
        making[path] = job
        let image = await job.value.image
        making[path] = nil
        // Let go meanwhile, or made by a view that asked first: the newest stays.
        if cache.updateValue(image, forKey: path) == nil { order.append(path) }
        if order.count > limit {
            for old in order.prefix(order.count - limit) { cache[old] = nil }
            order.removeFirst(order.count - limit)
        }
        return image
    }

    var count: Int { cache.count }

    /// Lets the icons go under memory pressure; each is made again when shown.
    func release() {
        cache = [:]
        order = []
    }

    static var limit: Int {
        get { shared.limit }
        set { shared.limit = newValue }
    }
    static func cached(_ path: String) -> NSImage? { shared.cached(path) }
    static func prepared(_ path: String) async -> NSImage { await shared.prepared(path) }
    static var count: Int { shared.count }
    static func release() { shared.release() }

    /// An image made on one thread and from then on used only on the main actor.
    struct Prepared: @unchecked Sendable {
        let image: NSImage
    }

    /// The app's icon drawn once into a bitmap of `pixels` a side, in the
    /// icon's own colour space; the icon as it is when that can't be done.
    nonisolated static func render(_ path: String) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path)
        var frame = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        guard let source = icon.cgImage(forProposedRect: &frame, context: nil, hints: nil) else { return icon }
        let space = source.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard let space,
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return icon }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let bitmap = context.makeImage() else { return icon }
        return NSImage(cgImage: bitmap, size: NSSize(width: pixels / 2, height: pixels / 2))
    }
}

/// An app's icon at `side` points: there at once when it has been made
/// before, otherwise as soon as it is, without holding up the view.
struct InstalledAppIcon: View {
    let path: String
    let side: CGFloat
    @State private var made: (path: String, image: NSImage)?

    var body: some View {
        Image(nsImage: AppIcons.cached(path) ?? (made?.path == path ? made?.image : nil) ?? AppIcons.placeholder)
            .resizable()
            .frame(width: side, height: side)
            .task(id: path) {
                guard AppIcons.cached(path) == nil else { return }
                let image = await AppIcons.prepared(path)
                guard !Task.isCancelled else { return }
                made = (path, image)
            }
    }
}
