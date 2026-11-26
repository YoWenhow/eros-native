import SwiftUI
import UIKit

struct ReaderPageRecoveryState: Equatable {
    let message: String
    let retryTitle: String
    let accessibilityLabel: String
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
}

/// Used for an initial catalogue failure, where no page canvas exists yet.
struct ReaderPageRecoveryOverlay: UIViewRepresentable {
    let state: ReaderPageRecoveryState
    let onRetry: () -> Void
    func makeUIView(context: Context) -> ReaderPageRecoveryView {
        let view = ReaderPageRecoveryView()
        view.update(state, onRetry: onRetry)
        return view
    }
    func updateUIView(_ view: ReaderPageRecoveryView, context: Context) {
        view.update(state, onRetry: onRetry)
    }
}

/// Only the recovery action and overflowing text own touches. Blank space
/// remains available to the reader's existing page gestures.
@MainActor final class ReaderPageRecoveryView: UIView {
    private let panel = UIView()
    private let message = UILabel()
    private let statusScroll = ReaderPageStatusScrollView(frame: .zero)
    private let retry = UIButton(type: .system)
    private var onRetry: () -> Void = {}
    private var chromeInsets = UIEdgeInsets.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        message.numberOfLines = 0
        message.textColor = .label
        message.font = .preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        statusScroll.contentInsetAdjustmentBehavior = .never
        statusScroll.addSubview(message)
        retry.addTarget(self, action: #selector(retryPage), for: .touchUpInside)
        panel.addSubview(statusScroll); panel.addSubview(retry); addSubview(panel)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ state: ReaderPageRecoveryState, onRetry: @escaping () -> Void) {
        message.text = state.message
        chromeInsets.top = state.topInset; chromeInsets.bottom = state.bottomInset
        retry.setTitle(state.retryTitle, for: .normal)
        retry.accessibilityLabel = state.accessibilityLabel
        retry.isEnabled = true
        self.onRetry = onRetry
        setNeedsLayout()
    }
    @objc private func retryPage() {
        guard retry.isEnabled else { return }
        retry.isEnabled = false
        onRetry()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let available = bounds.inset(by: UIEdgeInsets(top: safeAreaInsets.top + chromeInsets.top,
            left: safeAreaInsets.left, bottom: safeAreaInsets.bottom + chromeInsets.bottom, right: safeAreaInsets.right))
        guard available.width > 0, available.height > 0 else { return }
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: message.traitCollection)
        if message.font != font { message.font = font }
        let textHeight = message.sizeThatFits(CGSize(width: max(0, available.width - 32), height: .greatestFiniteMagnitude)).height
        let margin: CGFloat = available.height >= 128 ? 24 : 0
        let height = min(max(0, available.height - margin), max(104, textHeight + 72))
        panel.frame = CGRect(x: available.minX, y: available.midY - height / 2, width: available.width, height: height)
        ReaderPageStatusLayout.apply(bounds: panel.bounds, message: message, scroll: statusScroll, retry: retry)
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if retry.point(inside: convert(point, to: retry), with: event) { return true }
        return statusScroll.isScrollEnabled && !statusScroll.isHidden &&
            statusScroll.point(inside: convert(point, to: statusScroll), with: event)
    }
}
