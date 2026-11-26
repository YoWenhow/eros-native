import UIKit

/// A short image must not clip its recovery action. Only the explanatory text
/// scrolls; retry stays outside that scroll view with a 48pt target.
@MainActor enum ReaderPageStatusLayout {
    static func apply(bounds: CGRect, message: UILabel, scroll: UIScrollView, retry: UIButton) {
        message.textAlignment = .center
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: message.traitCollection)
        if message.font != font { message.font = font }
        retry.contentHorizontalAlignment = .center
        retry.titleLabel?.textAlignment = .center
        let width = max(0, bounds.width - 32)
        let retryHeight: CGFloat = retry.isHidden ? 0 : 48
        let gap: CGFloat = retry.isHidden ? 0 : 8
        let available = max(0, bounds.height - 16 - retryHeight - gap)
        let textHeight = message.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let viewport = min(available, max(32, textHeight))
        let contentHeight = viewport + gap + retryHeight
        let top = retry.isHidden ? 8 : max(8, (bounds.height - contentHeight) / 2)
        scroll.isHidden = message.isHidden
        scroll.frame = CGRect(x: 16, y: top, width: width, height: viewport)
        message.frame = CGRect(x: 0, y: 0, width: width, height: textHeight)
        scroll.contentSize = CGSize(width: width, height: textHeight)
        scroll.isScrollEnabled = textHeight > viewport
        retry.frame = CGRect(x: 16, y: scroll.frame.maxY + gap, width: width, height: retryHeight)
    }
}

/// A marker for text scrolling, and a layout invalidation source at Dynamic Type changes.
@MainActor final class ReaderPageStatusScrollView: UIScrollView {
    private var sizeObserver: NSObjectProtocol?
    override init(frame: CGRect) {
        super.init(frame: frame)
        sizeObserver = NotificationCenter.default.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.superview?.setNeedsLayout()
                self?.superview?.superview?.setNeedsLayout()
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit { if let sizeObserver { NotificationCenter.default.removeObserver(sizeObserver) } }
}
