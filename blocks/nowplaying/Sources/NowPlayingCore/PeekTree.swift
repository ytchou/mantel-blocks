import BlockKit

/// The now-playing peek as view nodes: artwork or its placeholder, the track
/// and artist, and the speaker and volume bar once the volume is known.
/// Sizes, spacing and opacities are those of `NotchStyle` and of the in-app
/// peek this replaces.
enum PeekTree {
    static let width = 380.0
    static let height = 52.0

    /// `NotchStyle.leadingImageSize` and `NotchStyle.leadingImageRadius`.
    static let artworkSize = 36.0
    static let artworkRadius = 8.0
    static let barWidth = 64.0

    /// - Parameter artwork: an `image` node for the track's artwork, or nil
    ///   for the placeholder box.
    static func root(title: String, subtitle: String, artwork: ViewNode?, volume: Double?, isMuted: Bool) -> ViewNode {
        var children: [ViewNode] = [
            artwork ?? placeholder,
            .vstack(spacing: 2, alignment: .start, [
                .text(title, style: .title),
                .text(subtitle, style: .secondary),
            ]),
            .spacer(minLength: 4),
        ]
        if let volume {
            children.append(.symbol(isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 12, opacity: 0.8, width: 18))
            children.append(
                .progress(isMuted ? 0 : volume, width: barWidth)
                    .accessibilityLabel(isMuted ? "Muted" : "Volume \(Int((volume * 100).rounded())) percent")
            )
        }
        // `NotchStyle.padding`; the spacing is left out, so the app uses `NotchStyle.spacing`.
        return .hstack(padding: .init(horizontal: 18), children)
    }

    /// A rounded box with a note symbol, where the artwork would be.
    static let placeholder = ViewNode.box(
        width: artworkSize, height: artworkSize, cornerRadius: artworkRadius, fillOpacity: 0.12,
        .symbol("music.note", size: 15, opacity: 0.8)
    )
}
