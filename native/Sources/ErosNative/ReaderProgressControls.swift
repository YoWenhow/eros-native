import SwiftUI
import ErosCore
import ErosServices

enum ReaderThumbnailSource {
    case online(ReaderDocument, PreviewImageLoader)
    case offline(@Sendable (PageIndex) async throws -> UIImage?)
}

struct ReaderProgressControls: View {
    let selected: Int
    let total: Int
    let rightToLeft: Bool
    let showThumbnails: Bool
    let thumbnailSource: ReaderThumbnailSource
    let blockedThumbnailPages: Set<Int>
    let imageRulesRevision: Int
    let active: Bool
    let onScrubbing: (Bool) -> Void
    let onNavigate: (Int) -> Void

    @State private var draft: Double?
    @GestureState private var dragActive = false

    private var lastPage: Int { max(0, total - 1) }
    private var canScrub: Bool { active && lastPage > 0 }
    private var displayedPage: Int { min(lastPage, max(0, Int((draft ?? Double(selected)).rounded()))) }
    private var progressFraction: Double {
        guard lastPage > 0 else { return 0 }
        return (draft ?? Double(displayedPage)) / Double(lastPage)
    }

    private var accessibleProgress: Binding<Double> {
        Binding(get: { Double(displayedPage) }, set: { value in
            guard draft == nil else { return }
            jump(to: Int(value.rounded()))
        })
    }

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            VStack(spacing: 6) {
                if showThumbnails {
                    ReaderThumbnailStrip(selection: displayedPage, total: total, rightToLeft: rightToLeft,
                        source: thumbnailSource, blockedPages: blockedThumbnailPages,
                        imageRulesRevision: imageRulesRevision, onSelect: onNavigate)
                }
                progressBar
            }
        }
        .onChange(of: dragActive) { _, dragging in if !dragging { cancelScrubbing() } }
        .onChange(of: active) { _, value in if !value { cancelScrubbing() } }
        .onChange(of: rightToLeft) { cancelScrubbing() }
        .onChange(of: total) { cancelScrubbing() }
        .onDisappear(perform: cancelScrubbing)
    }

    private var progressBar: some View {
        VStack(spacing: 5) {
            ReaderProgressTrack(fraction: progressFraction, rightToLeft: rightToLeft, isScrubbing: draft != nil)
                .frame(height: 10)
            pageCounts.padding(.horizontal, ReaderProgressTrack.Geometry.horizontalPadding)
        }
        .padding(.vertical, 6)
        .frame(minHeight: 47)
        .overlay {
            // The whole capsule stays draggable even though the track is thin.
            GeometryReader { proxy in
                Color.clear
                    .contentShape(.interaction, Capsule())
                    .gesture(scrub(width: proxy.size.width), isEnabled: canScrub)
            }
        }
        .focusable(canScrub, interactions: .edit)
        .onKeyPress(.leftArrow) { adjust(by: rightToLeft ? 1 : -1) }
        .onKeyPress(.rightArrow) { adjust(by: rightToLeft ? -1 : 1) }
        .accessibilityRepresentation {
            Slider(value: accessibleProgress, in: 0...Double(max(1, lastPage)), step: 1) {
                Text("阅读进度")
            }
            .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
            .accessibilityValue("第 \(displayedPage + 1) 页，共 \(total) 页，剩余 \(lastPage - displayedPage) 页")
            .disabled(!canScrub)
        }
        .accessibleGlass(in: Capsule(), interactive: false)
    }

    private var pageCounts: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                remainingPages.hidden()
                pageNumber.frame(maxWidth: .infinity)
                remainingPages
            }
            HStack {
                pageNumber
                Spacer(minLength: 4)
                remainingPages
            }
            VStack(spacing: 2) {
                pageNumber
                remainingPages
            }
        }
        .font(.caption2)
        .monospacedDigit()
    }

    private var pageNumber: some View {
        Text("\(displayedPage + 1) / \(total)").fixedSize()
    }

    private var remainingPages: some View {
        Text("剩余 \(lastPage - displayedPage) 页")
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private func scrub(width: CGFloat) -> some Gesture {
        let geometry = ReaderProgressTrack.Geometry(width: width, rightToLeft: rightToLeft)
        return DragGesture(minimumDistance: 0)
            .updating($dragActive) { _, tracking, _ in tracking = true }
            .onChanged { value in
                guard canScrub, geometry.length > 0 else { return }
                let started = draft == nil
                draft = geometry.fraction(at: value.location.x) * Double(lastPage)
                if started { onScrubbing(true) }
            }
            .onEnded { value in
                guard canScrub, draft != nil else { return }
                let page = Int((geometry.fraction(at: value.location.x) * Double(lastPage)).rounded())
                jump(to: page)
                cancelScrubbing()
            }
    }

    private func adjust(by amount: Int) -> KeyPress.Result {
        guard canScrub, draft == nil else { return .ignored }
        jump(to: displayedPage + amount)
        return .handled
    }

    private func jump(to page: Int) {
        guard canScrub, (0...lastPage).contains(page), page != selected else { return }
        onNavigate(page)
    }

    private func cancelScrubbing() {
        guard draft != nil else { return }
        draft = nil
        onScrubbing(false)
    }
}

private struct ReaderProgressTrack: View {
    let fraction: Double
    let rightToLeft: Bool
    let isScrubbing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Geometry {
        static let horizontalPadding: CGFloat = 14
        static let thumbSize = CGSize(width: 15, height: 10)
        let width: CGFloat
        let rightToLeft: Bool

        private var firstCenter: CGFloat { min(width / 2, Self.horizontalPadding + Self.thumbSize.width / 2) }
        var length: CGFloat { max(0, width - 2 * firstCenter) }

        func fraction(at location: CGFloat) -> Double {
            guard length > 0 else { return 0 }
            let position = Double(max(0, min(1, (location - firstCenter) / length)))
            return rightToLeft ? 1 - position : position
        }

        func thumbCenter(for fraction: Double) -> CGFloat {
            firstCenter + length * CGFloat(rightToLeft ? 1 - fraction : fraction)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let geometry = Geometry(width: proxy.size.width, rightToLeft: rightToLeft)
            let centerY = proxy.size.height / 2
            ZStack {
                Capsule()
                    .fill(Color.primary.opacity(0.20))
                    .frame(width: geometry.length, height: 2.5)
                    .overlay(alignment: rightToLeft ? .trailing : .leading) {
                        Capsule().fill(.tint)
                            .frame(width: geometry.length * CGFloat(fraction))
                    }
                    .position(x: proxy.size.width / 2, y: centerY)
                thumb
                    .position(x: geometry.thumbCenter(for: fraction), y: centerY)
            }
            .environment(\.layoutDirection, .leftToRight)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var thumb: some View {
        let scale = isScrubbing && !reduceMotion ? 2.4 : 1.0
        // Keep the thumb's glass distinct from the surrounding progress capsule.
        return GlassEffectContainer(spacing: 0) {
            Color.clear
                .frame(width: Geometry.thumbSize.width * scale, height: Geometry.thumbSize.height * scale)
                .background {
                    if isScrubbing {
                        Color.clear.accessibleGlass(in: Capsule())
                    } else {
                        Capsule().fill(.white)
                            .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    }
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: isScrubbing)
        }
    }
}

private struct ReaderThumbnailStrip: View {
    let selection: Int
    let total: Int
    let rightToLeft: Bool
    let source: ReaderThumbnailSource
    let blockedPages: Set<Int>
    let imageRulesRevision: Int
    let onSelect: (Int) -> Void

    private let height: CGFloat = 105

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(0..<total, id: \.self) { index in
                        thumbnailButton(index)
                            .id(index)
                    }
                }
                .scrollTargetLayout()
                .frame(height: height)
            }
            .scrollIndicators(.hidden)
            .clipped()
            .defaultScrollAnchor(.center, for: .alignment)
            .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
            .onChange(of: selection, initial: true) { _, page in
                proxy.scrollTo(page, anchor: .center)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: height)
        .accessibleGlass(in: RoundedRectangle(cornerRadius: 20), interactive: false)
        .accessibilityLabel("页面缩略图")
    }

    private func thumbnailButton(_ index: Int) -> some View {
        Button { onSelect(index) } label: {
            VStack(spacing: 2) {
                ReaderThumbnailImage(index: index, source: source, blocked: blockedPages.contains(index),
                    imageRulesRevision: imageRulesRevision)
                    .frame(width: 50, height: 61)
                Text("\(index + 1)")
                    .font(.caption2)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(width: 56, height: 81)
            .background(selection == index ? Color.primary.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("第 \(index + 1) 页")
        .accessibilityAddTraits(selection == index ? .isSelected : [])
    }
}

private struct ReaderThumbnailImage: View {
    let index: Int
    let source: ReaderThumbnailSource
    let blocked: Bool
    let imageRulesRevision: Int

    private struct LoadKey: Equatable {
        let visible: Bool
        let blocked: Bool
        let imageRulesRevision: Int
    }

    private enum Preview {
        case online(ReaderPage, PreviewImageLoader, SessionScope)
        case offline(UIImage)
    }

    @State private var visible = false
    @State private var preview: Preview?
    @State private var presentedKey: LoadKey?

    private var loadKey: LoadKey {
        LoadKey(visible: visible, blocked: blocked, imageRulesRevision: imageRulesRevision)
    }

    var body: some View {
        Group {
            if !blocked, presentedKey == loadKey, let preview {
                switch preview {
                case let .online(page, loader, scope):
                    if let thumbnail = page.thumbnail {
                        OnlinePreview(url: thumbnail.url, loader: loader, scope: scope, size: thumbnail.size,
                            offset: thumbnail.horizontalOffset, imagePageURL: page.pageURL)
                    }
                case let .offline(image):
                    Image(uiImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            } else {
                Image(systemName: blocked ? "eye.slash" : "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
        .onScrollVisibilityChange(threshold: 0.1) { visible = $0 }
        .task(id: loadKey) {
            preview = nil
            let key = loadKey
            guard key.visible, !key.blocked, let page = try? PageIndex(index) else { return }
            do {
                // A fast sweep over the bar skips previews that never settle on screen.
                try await Task.sleep(for: .milliseconds(150))
                let result: Preview?
                switch source {
                case let .online(document, loader):
                    let item = try await document.page(at: page)
                    result = item.thumbnail == nil ? nil : .online(item, loader, document.scope)
                case let .offline(load):
                    result = try await load(page).map(Preview.offline)
                }
                try Task.checkCancellation()
                guard key == loadKey else { return }
                preview = result
                presentedKey = key
            } catch {
                // The tile stays available to navigate to, even without a preview.
            }
        }
    }
}
