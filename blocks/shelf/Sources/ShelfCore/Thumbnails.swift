import AppKit
import BlockKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Makes the picture of a file: its Finder icon at once, and its Quick Look
/// thumbnail later. Both as square PNG bytes, the picture fitted and
/// centred, because the app fills and clips an `image` node to a square
/// while the in-app tile fitted it. Tests pass their own.
struct Thumbnailer: Sendable {
    /// The Finder icon, or nil.
    var icon: @MainActor @Sendable (URL) -> Data?
    /// The Quick Look thumbnail with this side in pixels, or nil when there is none.
    var thumbnail: @Sendable (URL, Int) async -> Data?

    /// Neither: tiles of files show a placeholder.
    static let none = Thumbnailer(icon: { _ in nil }, thumbnail: { _, _ in nil })

    static let system = Thumbnailer(
        icon: { url in
            let image = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
            var rect = CGRect(x: 0, y: 0, width: Thumbnails.pixels, height: Thumbnails.pixels)
            guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
            return Thumbnails.squarePNG(cgImage, side: Thumbnails.pixels)
        },
        thumbnail: { url, side in
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                       scale: 1, representationTypes: .thumbnail)
            return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                    continuation.resume(returning: representation.flatMap { Thumbnails.squarePNG($0.cgImage, side: side) })
                }
            }
        }
    )
}

/// File pictures as `image` nodes, cached by path. The icon is the
/// placeholder until the thumbnail arrives, and the final picture for
/// folders and files Quick Look cannot draw.
@MainActor
final class Thumbnails {
    /// A tile's picture side in points, and in pixels at 2x.
    static let side = 64.0
    nonisolated static let pixels = 128

    /// One picture: its node, and its asset id for a drag image.
    struct Picture {
        let node: ViewNode
        let asset: String
    }

    private let thumbnailer: Thumbnailer
    private let makeNode: (Data) -> ViewNode
    /// Called when a thumbnail arrived, so the tree is sent again.
    private let onChange: () -> Void
    private var pictures: [String: Picture] = [:]
    private var requested: Set<String> = []
    /// The whole cache is dropped when it grows past this; a shelf rarely
    /// holds more. Switch to an LRU if shelves get large.
    private static let limit = 200

    init(thumbnailer: Thumbnailer, makeNode: @escaping (Data) -> ViewNode, onChange: @escaping () -> Void) {
        self.thumbnailer = thumbnailer
        self.makeNode = makeNode
        self.onChange = onChange
    }

    /// The best picture so far, or nil. Asks for it the first time.
    func picture(for url: URL) -> Picture? {
        let key = url.path(percentEncoded: false)
        if !requested.contains(key) { request(url, key: key) }
        return pictures[key]
    }

    private func request(_ url: URL, key: String) {
        if requested.count >= Self.limit {
            requested.removeAll()
            pictures.removeAll()
        }
        requested.insert(key)
        if let icon = thumbnailer.icon(url) { pictures[key] = picture(icon) }
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard !isFolder else { return }
        let thumbnailer = self.thumbnailer
        Task { [weak self] in
            guard let bytes = await thumbnailer.thumbnail(url, Self.pixels), let self,
                  self.requested.contains(key) else { return }
            self.pictures[key] = self.picture(bytes)
            self.onChange()
        }
    }

    private func picture(_ bytes: Data) -> Picture {
        Picture(node: makeNode(bytes), asset: Assets.id(for: bytes))
    }

    /// The image fitted and centred on a transparent square, as PNG.
    nonisolated static func squarePNG(_ image: CGImage, side: Int) -> Data? {
        guard image.width > 0, image.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let width = Double(image.width), height = Double(image.height)
        let scale = min(Double(side) / width, Double(side) / height)
        let rect = CGRect(x: (Double(side) - width * scale) / 2, y: (Double(side) - height * scale) / 2,
                          width: width * scale, height: height * scale)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        guard let square = context.makeImage() else { return nil }
        // PNG encoding is copied in Rename's RenamePipeline on purpose: separate
        // packages, and BlockKit may import only Foundation, CryptoKit and Dispatch.
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, square, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
