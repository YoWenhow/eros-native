import SwiftUI
import ErosCore

struct ImageTransferProgressView: View {
    let owner: TransferOwner
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pageNumber: String {
        if case .reader(_, _, let page) = owner { return String(page.displayNumber) }
        return ""
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let progress = TransferProgress.shared.snapshot(owner: owner)
            let fraction = progress.received > 0 && !progress.isEstimated ? progress.fraction : nil
            // Only the track participates in layout. Neither label may move
            // its midpoint when the page number or percentage changes width.
            ReaderLoadingTrack(fraction: fraction, reduceMotion: reduceMotion)
                .frame(width: 180, height: 4)
                .overlay(alignment: .top) {
                    Text(pageNumber).font(.caption).monospacedDigit()
                        .fixedSize()
                        .alignmentGuide(.top) { $0[.top] - 12 }
                }
                .overlay(alignment: .trailing) {
                    if let fraction {
                        Text("\(Int(fraction * 100))%")
                            .font(.caption).monospacedDigit().fixedSize()
                            .padding(.leading, 8)
                            .frame(width: 0, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("第 " + pageNumber + " 页加载")
            .accessibilityValue(fraction.map { "\(Int($0 * 100))%" } ?? "正在加载")
        }
        .allowsHitTesting(false)
    }
}

private struct ReaderLoadingTrack: View {
    let fraction: Double?
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15))
                if let fraction {
                    Capsule().fill(.tint)
                        .frame(width: geometry.size.width * min(1, max(0, fraction)))
                } else {
                    TimelineView(.animation(paused: reduceMotion)) { context in
                        let phase = reduceMotion ? 0.5 : context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 1.1) / 1.1
                        Capsule().fill(.tint)
                            .frame(width: geometry.size.width * 0.3)
                            .offset(x: geometry.size.width * (1.3 * phase - 0.3))
                    }
                }
            }
            .clipShape(Capsule())
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

@MainActor final class ReaderTransferOverlay:UIView {
    private let content:UIView
    init(owner:TransferOwner) {
        content=UIHostingConfiguration { ImageTransferProgressView(owner:owner) }.margins(.all,0).makeContentView()
        super.init(frame:.zero)
        isUserInteractionEnabled=false;backgroundColor = .clear
        content.backgroundColor = .clear;addSubview(content)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews();content.frame=bounds }
}
