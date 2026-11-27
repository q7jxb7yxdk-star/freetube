import SwiftUI
import Kingfisher
import UIKit

/// Horizontal compact video row — used in search results, history, library lists.
///
/// Set `showsMoreMenu: true` to render a trailing ellipsis Menu next to the row content
/// (open in browser, copy URL, favorites, add to playlist, downloads). The Menu lives as a
/// sibling of the main tap target so taps on it don't trigger `onTap`.
@available(iOS 17.0, *)
struct VideoRow: View {
    let video: Video
    var localThumbnailData: Data? = nil
    var onTap: () -> Void = {}
    var showsMoreMenu: Bool = false
    private let thumbnailSize = CGSize(width: 168, height: 96)

    /// Playback count + relative upload date joined by a middle dot. Either half can be empty
    /// (older listings sometimes omit one), so we filter before joining to avoid stray separators.
    private var statsLine: String {
        [video.viewCountString, video.publishedRelative ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onTap) {
                content
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)

            if showsMoreMenu {
                VideoMoreActionsMenu(video: video)
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let localThumbnailData, let image = UIImage(data: localThumbnailData) {
            Image(uiImage: image).resizable()
        } else {
            KFImage(video.thumbnailURL)
                .thumbnail(size: thumbnailSize) {
                    Color.gray.opacity(0.2)
                }
                .resizable()
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                thumbnail
                    .scaledToFill()
                    .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if !video.durationString.isEmpty {
                    Text(video.durationString)
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.black.opacity(0.75))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .padding(4)
                }
            }
            .frame(width: thumbnailSize.width, height: thumbnailSize.height)

            VStack(alignment: .leading, spacing: 4) {
                Text(video.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(video.channelName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !statsLine.isEmpty {
                    Text(statsLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
    }
}
