import SwiftUI
import UIKit
import QuartzCore
import ErosCore
import ErosServices

/// One decoded page at a time. Page swipes only fire at fit scale; while zoomed,
/// the scroll view owns panning. Rotation refits this page without changing index.
struct ZoomReaderAdapter: UIViewRepresentable {
    let image: UIImage?
    let pageID: Int
    let rightToLeft: Bool
    let active: Bool
    let previewRevision: UUID
    let onTap: () -> Void
    let pagingTrack: ReaderPagingTrack?
    let onSwipe: (Int) -> Bool
    let adjacent: (ReaderSpread, _ cachedOnly: Bool) async -> ReaderAdjacentPreview?
    let showsPreviewProgress: Bool
    let onDismiss: () -> Void
    let onInteraction: () -> Void
    let blockedLoader: ReaderViewModel?
    let memory: ReaderImageMemory
    let onReveal: () -> Void
    var onZoomStart: () -> Void = {}
    var onZoomChanged: (Bool) -> Void = { _ in }
    var recovery: ReaderPageRecoveryState? = nil
    var onRetry: () -> Void = {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> ReaderPagingView<ReaderZoomScrollView> {
        let view = ReaderZoomScrollView()
        view.delegate = context.coordinator; view.backgroundColor = .systemBackground
        view.contentInsetAdjustmentBehavior = .never
        view.showsHorizontalScrollIndicator = false; view.showsVerticalScrollIndicator = false
        view.maximumZoomScale = 6; view.minimumZoomScale = 1
        view.addSubview(view.picture)
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap))
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2; single.require(toFail: double)
        single.delegate = context.coordinator; double.delegate = context.coordinator
        view.addGestureRecognizer(single); view.addGestureRecognizer(double)
        let container = ReaderPagingView(view)
        let pager = container.pager
        let coordinator = context.coordinator
        coordinator.pager = pager
        pager.preview = { [weak coordinator] in await coordinator?.parent.adjacent($0, $1) }
        pager.displayedPreview = { [weak view] in
            guard let image = view?.picture.image else { return nil }
            return ReaderAdjacentPreview(pages: [.init(image: image,
                ratio: image.size.width / max(1, image.size.height), message: nil)])
        }
        pager.commit = { [weak coordinator] in coordinator?.parent.onSwipe($0) ?? false }
        pager.dismiss = { [weak coordinator] in coordinator?.parent.onDismiss() }
        pager.interaction = { [weak coordinator] in coordinator?.parent.onInteraction() }
        return container
    }
    static func dismantleUIView(_ container: ReaderPagingView<ReaderZoomScrollView>, coordinator: Coordinator) {
        container.pager.stop()
    }
    func updateUIView(_ container: ReaderPagingView<ReaderZoomScrollView>, context: Context) {
        let view = container.reader
        let pager = container.pager
        guard !pager.dismissalCommitted else { return }
        pager.showsPreviewProgress = showsPreviewProgress
        let discardPreview = !active || context.coordinator.parent.previewRevision != previewRevision
        let directionChanged = context.coordinator.parent.rightToLeft != rightToLeft
        context.coordinator.parent = self
        let settled = pager.present(pageID, track: pagingTrack, active: active, invalidated: discardPreview || directionChanged)
        if discardPreview || directionChanged { view.cancelPagingAnimations() }
        let pageChanged = view.pageID != pageID
        if pageChanged || view.picture.image !== image {
            view.display(image, pageID: pageID, rightToLeft: rightToLeft, animate: !settled && !discardPreview)
        }
        let digest = blockedLoader?.blockedImage?.digest
        if view.blockedDigest != digest {
            view.blockedOverlay?.removeFromSuperview(); view.blockedOverlay = nil; view.blockedDigest = digest
            if let blockedLoader {
                let overlay = ReaderImageBlockOverlay(loader: blockedLoader, memory: memory, onReveal: onReveal)
                overlay.frame = view.bounds; view.blockedOverlay = overlay; view.addSubview(overlay)
            }
        }
        if let recovery {
            let status = view.recoveryView ?? ReaderPageRecoveryView()
            if view.recoveryView == nil { view.recoveryView = status; view.addSubview(status) }
            status.update(recovery, onRetry: onRetry); status.frame = view.bounds
        } else { view.recoveryView?.removeFromSuperview(); view.recoveryView = nil }
        pager.contentDidUpdate(ready: image != nil || recovery != nil || blockedLoader != nil)
        let coordinator = context.coordinator
        Task { @MainActor [weak view, weak coordinator] in
            guard let view, view.window != nil else { return }; coordinator?.parent.onZoomChanged(view.zoomScale > 1.01)
        }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        weak var pager: ReaderHorizontalPager?
        var parent: ZoomReaderAdapter
        init(_ parent: ZoomReaderAdapter) { self.parent = parent }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? ReaderZoomScrollView)?.picture }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? ReaderZoomScrollView)?.centerPicture()
            pager?.zoomDidChange()
            Task { @MainActor [weak self, weak scrollView] in
                guard let self, let scrollView, scrollView.window != nil else { return }
                self.parent.onZoomChanged(scrollView.zoomScale > 1.01)
            }
        }
        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            if let pinch = scrollView.pinchGestureRecognizer, pinch.state == .began || pinch.state == .changed {
                pager?.beginZoom()
                parent.onZoomStart()
            }
        }
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            pager?.endZoom()
        }
        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var target = touch.view
            while let view = target {
                if view is UIControl || view is ReaderPageStatusScrollView || view is ReaderImageBlockOverlay { return false }
                target = view.superview
            }
            return true
        }
        @objc func tap() { parent.onTap() }
        @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? ReaderZoomScrollView, view.picture.image != nil else { return }
            pager?.beginZoom()
            parent.onZoomStart()
            if view.zoomScale > 1.01 { view.setZoomScale(1, animated: !UIAccessibility.isReduceMotionEnabled); return }
            let point = recognizer.location(in: view.picture), scale: CGFloat = 3
            let width = view.bounds.width / scale, height = view.bounds.height / scale
            view.zoom(to: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height), animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }
}

final class ReaderZoomScrollView: UIScrollView {
    let picture = UIImageView()
    var blockedOverlay: ReaderImageBlockOverlay?
    var recoveryView: ReaderPageRecoveryView?
    var blockedDigest: String?
    var pageID: Int?
    var refit = true
    private var previousSize = CGSize.zero
    private var outgoing: UIImageView?
    private var transitionStart: CFTimeInterval?
    private var entryShift: CGFloat?
    private var animateArrival = true
    private let pageDuration = 0.24
    func display(_ image: UIImage?, pageID: Int, rightToLeft: Bool, animate: Bool) {
        let oldPage = self.pageID, oldImage = picture.image
        let changedPage = oldPage != nil && oldPage != pageID
        if oldPage != pageID { animateArrival = animate }
        if changedPage {
            cancelPagingAnimations()
            if animate {
                transitionStart = CACurrentMediaTime()
                if let oldPage, abs(oldPage - pageID) == 1, !UIAccessibility.isReduceMotionEnabled {
                    entryShift = ((pageID > oldPage) != rightToLeft ? 1 : -1) * bounds.width
                }
            }
        }
        if zoomScale != 1 { setZoomScale(1, animated: false) }
        self.pageID = pageID; picture.image = image; refit = true
        setNeedsLayout(); layoutIfNeeded()
        if changedPage, animate, let oldImage, !UIAccessibility.isReduceMotionEnabled {
            // Reuse the already-decoded UIImage. No whole-scroll-view snapshot or
            // render-server push transition; animate only image-layer properties.
            let leaving = UIImageView(image: oldImage)
            leaving.frame = bounds; leaving.contentMode = .scaleAspectFit
            leaving.backgroundColor = .systemBackground; leaving.isUserInteractionEnabled = false
            addSubview(leaving); outgoing = leaving
            let animation = entryShift.map { makeAnimation("transform.translation.x", from: 0, to: -$0, duration: pageDuration) }
                ?? makeAnimation("opacity", from: 1, to: 0, duration: 0.14)
            animation.fillMode = .forwards; animation.isRemovedOnCompletion = false
            leaving.layer.add(animation, forKey: "readerExit")
            DispatchQueue.main.asyncAfter(deadline: .now() + pageDuration) { [weak self, weak leaving] in
                leaving?.removeFromSuperview()
                if self?.outgoing === leaving { self?.outgoing = nil }
            }
        }
        if animate, animateArrival, image != nil, (changedPage || oldImage == nil), !UIAccessibility.isReduceMotionEnabled {
            let remaining = pageDuration - (CACurrentMediaTime() - (transitionStart ?? 0))
            let animation: CABasicAnimation
            if let entryShift, remaining > 0.04 {
                animation = makeAnimation("transform.translation.x", from: entryShift * CGFloat(remaining / pageDuration), to: 0, duration: remaining)
                animation.isAdditive = true
            } else { animation = makeAnimation("opacity", from: 0, to: 1, duration: 0.12) }
            picture.layer.add(animation, forKey: "readerEnter")
        }
    }
    private func makeAnimation(_ key: String, from: CGFloat, to: CGFloat, duration: Double) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from; animation.toValue = to; animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let maximum = Float(window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
        return animation
    }
    fileprivate func cancelPagingAnimations() {
        outgoing?.removeFromSuperview(); outgoing = nil
        picture.layer.removeAnimation(forKey: "readerEnter")
        transitionStart = nil; entryShift = nil
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        for overlay in [blockedOverlay as UIView?, recoveryView].compactMap({ $0 }) {
            overlay.bounds = CGRect(origin: .zero, size: bounds.size)
            overlay.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        guard bounds.width > 0, bounds.height > 0, let image = picture.image else { return }
        if refit || bounds.size != previousSize {
            if previousSize != .zero && bounds.size != previousSize {
                cancelPagingAnimations()
            }
            let keepZoom = !refit && previousSize.width == bounds.width
            let zoom = keepZoom ? zoomScale : 1
            previousSize = bounds.size; refit = false
            if zoomScale != 1 { setZoomScale(1, animated: false) }
            let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
            picture.bounds = CGRect(origin: .zero, size: CGSize(width: image.size.width * fit, height: image.size.height * fit))
            contentSize = picture.bounds.size; contentOffset = .zero
            if zoom > 1 { setZoomScale(zoom, animated: false) }
        }
        centerPicture()
    }
    func centerPicture() {
        picture.center = CGPoint(x: max(bounds.width, contentSize.width) / 2, y: max(bounds.height, contentSize.height) / 2)
    }
}
