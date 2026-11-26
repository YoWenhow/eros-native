import SwiftUI
import UIKit
import ErosServices

@MainActor extension UIScrollView {
    var hasActivePan: Bool {
        panGestureRecognizer.state == .began || panGestureRecognizer.state == .changed
    }
    func interruptUserScrollForTab(includeScrollAnimation: Bool = false) {
        let hasFinger = isTracking || isDragging || hasActivePan
        let shouldStop = hasFinger || isDecelerating || (includeScrollAnimation && isScrollAnimating)
        if hasFinger {
            panGestureRecognizer.isEnabled = false
            panGestureRecognizer.isEnabled = true
        }
        if shouldStop { stopScrollingAndZooming() }
    }
}

/// The run loop holds a link only while its viewport is being observed.
@MainActor final class NativeScrollFrames: NSObject {
    private let tick: @MainActor (CADisplayLink) -> Void
    private init(tick: @escaping @MainActor (CADisplayLink) -> Void) { self.tick = tick }

    static func observe<Owner: AnyObject>(_ owner: Owner,
        _ frame: @escaping @MainActor (Owner) -> Void) -> CADisplayLink {
        let observer = NativeScrollFrames { [weak owner] link in
            guard let owner else { link.invalidate(); return }
            frame(owner)
        }
        let link = CADisplayLink(target: observer, selector: #selector(displayFrame(_:)))
        link.add(to: .main, forMode: .common)
        return link
    }

    @objc private func displayFrame(_ link: CADisplayLink) { tick(link) }
}

/// A page retains its own main scroll view, obtained only from a marker inside
/// that scroll view's real content. No global view search or screen hit-testing.
@MainActor final class NativePageScroll: ObservableObject {
    private weak var scroll: UIScrollView?
    private weak var searchFirstMarker: UIView?
    private var searchStart: (owner: UUID, align: @MainActor (Bool) -> Void)?
    private var searchArrival = SearchListArrival()
    private var displayLink: CADisplayLink?
    private var targetY: CGFloat?
    private var settledFrames = 0
    private var lastVisibleY: CGFloat?
    private var enabled = true
    private(set) var scrollingToTop = false
    func position(forTagSearch: Bool) -> TabScrollInteraction.Position {
        guard enabled, let scroll, scroll.window != nil else { return .unavailable }
        let moving = scroll.isTracking || scroll.isDragging || scroll.isDecelerating || scroll.hasActivePan
        let restingY = -scroll.adjustedContentInset.top
        if forTagSearch {
            let visibleY = scroll.layer.presentation()?.bounds.origin.y ?? scroll.contentOffset.y
            return TabScrollInteraction.tagSearchPosition(returning: scrollingToTop,
                userMoving: moving || scroll.isScrollAnimating, firstRowVisible: firstSearchRowIsVisible(in: scroll),
                layoutY: Double(scroll.contentOffset.y), visibleY: Double(visibleY), restingY: Double(restingY))
        }
        return TabScrollInteraction.position(returning: scrollingToTop, userMoving: moving,
            atTop: searchStart == nil ? scroll.contentOffset.y <= restingY + 1 : firstSearchRowIsVisible(in: scroll))
    }
    func attach(_ scroll: UIScrollView) {
        guard enabled, scroll.window != nil, !LibraryTabActions.hasPresentedModal else { return }
        if self.scroll !== scroll { cancel(); self.scroll = scroll }
    }
    func registerSearchStart(owner: UUID, align: @escaping @MainActor (Bool) -> Void) {
        searchStart = (owner, align)
    }
    func removeSearchStart(owner: UUID) {
        guard searchStart?.owner == owner else { return }
        cancel()
        searchStart = nil
        searchFirstMarker = nil
    }
    func markSearchStart(_ view: UIView, first: Bool, in primary: UIScrollView) {
        if first, primary === scroll { searchFirstMarker = view }
        else if searchFirstMarker === view { searchFirstMarker = nil }
    }

    private func firstSearchRowRect(in scroll: UIScrollView) -> CGRect? {
        guard let marker = searchFirstMarker, marker.window != nil, marker.isDescendant(of: scroll) else { return nil }
        var ancestor: UIView? = marker
        while let view = ancestor, view !== scroll {
            if view is UITableViewCell || view is UICollectionViewCell { return view.convert(view.bounds, to: scroll) }
            ancestor = view.superview
        }
        return marker.bounds.isEmpty ? nil : marker.convert(marker.bounds, to: scroll)
    }

    private func firstSearchRowIsVisible(in scroll: UIScrollView) -> Bool {
        guard let rect = firstSearchRowRect(in: scroll), !rect.isEmpty else { return false }
        let viewport = scroll.bounds.inset(by: scroll.adjustedContentInset)
        return rect.minY >= viewport.minY - 1 && rect.minY < viewport.maxY &&
            (rect.maxY <= viewport.maxY + 1 || abs(rect.minY - viewport.minY) <= 1)
    }

    func activate() { enabled = true }
    func deactivate() { enabled = false; cancel() }
    func scrollToTop() {
        guard enabled, let scroll, scroll.window != nil, !scrollingToTop else { return }
        scroll.interruptUserScrollForTab(includeScrollAnimation: true)
        scroll.layoutIfNeeded()
        let y = -scroll.adjustedContentInset.top
        if let searchStart {
            guard !firstSearchRowIsVisible(in: scroll) else { return }
            scrollingToTop = true
            searchArrival = SearchListArrival()
            lastVisibleY = nil
            searchStart.align(!UIAccessibility.isReduceMotionEnabled)
        } else {
            guard abs(scroll.contentOffset.y - y) > 1 else { return }
            scrollingToTop = true; targetY = y; settledFrames = 0; lastVisibleY = nil
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y),
                animated: !UIAccessibility.isReduceMotionEnabled)
        }
        startDisplayLink()
    }
    private func startDisplayLink() {
        guard displayLink == nil else { return }
        displayLink = NativeScrollFrames.observe(self) { $0.frame() }
    }

    private func cancel(stopMotion: Bool = true) {
        displayLink?.invalidate(); displayLink = nil
        if stopMotion, scrollingToTop, let scroll { scroll.setContentOffset(scroll.contentOffset, animated: false) }
        scrollingToTop = false; targetY = nil; settledFrames = 0; lastVisibleY = nil
    }
    private func frame() {
        guard enabled, let scroll, scroll.window != nil else { deactivate(); return }
        // A new drag owns the scroll immediately; no deferred return is queued.
        guard !scroll.hasActivePan else {
            cancel(stopMotion: false); return
        }
        let top = -scroll.adjustedContentInset.top
        if searchStart == nil, targetY != top {
            // Search drawers, rotation and the refresh header may change insets
            // while moving. Settle against the current real top, not an old one.
            targetY = top; settledFrames = 0
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: top),
                animated: !UIAccessibility.isReduceMotionEnabled)
        }
        let visibleY = scroll.layer.presentation()?.bounds.origin.y ?? scroll.contentOffset.y
        // A touch or a relayout can also stop UIKit short of its destination.
        // Release ownership once the viewport is stationary so a new tap works.
        let positionSettled = lastVisibleY.map { abs($0 - visibleY) <= 0.25 } ?? false
        lastVisibleY = visibleY
        let stationary = positionSettled && !scroll.isScrollAnimating && !scroll.isDecelerating &&
            abs(visibleY - scroll.contentOffset.y) <= 1
        if let searchStart {
            let decision = searchArrival.sample(stationary: stationary, firstRowVisible: firstSearchRowIsVisible(in: scroll),
                touching: scroll.isTracking || scroll.isDragging)
            switch decision {
            case .alignFirstRow:
                // Once a row is materialized, use its actual layout and current
                // viewport. Keep the query, suggestions and navigation intact.
                let edge = scroll.bounds.minY + scroll.adjustedContentInset.top
                if let rect = firstSearchRowRect(in: scroll), rect.intersects(scroll.bounds), rect.minY < edge - 1 {
                    let y = max(top, scroll.contentOffset.y + rect.minY - edge)
                    if abs(y - scroll.contentOffset.y) > 0.5 {
                        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: false)
                    } else { searchStart.align(false) }
                } else { searchStart.align(false) }
            case .arrived, .stoppedShort: cancel(stopMotion: false)
            case .observe: break
            }
        } else if stationary {
            settledFrames += 1
            if settledFrames >= 2 { cancel(stopMotion: false) }
        } else { settledFrames = 0 }
    }
}

/// Install as a background of real row/content, never as an extra List row.
struct NativeScrollAnchor: UIViewRepresentable {
    let scroll: NativePageScroll
    var isSearchStart = false
    func makeUIView(context: Context) -> Marker { Marker(scroll: scroll, isSearchStart: isSearchStart) }
    func updateUIView(_ view: Marker, context: Context) {
        view.scroll = scroll; view.isSearchStart = isSearchStart; view.resolve()
    }

    @MainActor final class Marker: UIView {
        var scroll: NativePageScroll
        var isSearchStart: Bool
        init(scroll: NativePageScroll, isSearchStart: Bool) {
            self.scroll = scroll; self.isSearchStart = isSearchStart
            super.init(frame: .zero); isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func didMoveToWindow() { super.didMoveToWindow(); resolve() }
        override func layoutSubviews() { super.layoutSubviews(); resolve() }
        func resolve() {
            guard window != nil else { return }
            // A modal may inherit the underlying page's environment. Check
            // public controller containment too, including dismissal frames.
            var responder: UIResponder? = self
            while let current = responder {
                if let owner = current as? UIViewController {
                    var controller: UIViewController? = owner
                    while let value = controller {
                        guard value.presentingViewController == nil,
                              !value.isBeingPresented, !value.isBeingDismissed else { return }
                        controller = value.parent
                    }
                    break
                }
                responder = current.next
            }
            var ancestor = superview
            while let current = ancestor {
                if let primary = current as? UIScrollView {
                    scroll.attach(primary)
                    scroll.markSearchStart(self, first: isSearchStart, in: primary)
                    return
                }
                ancestor = current.superview
            }
        }
    }
}
