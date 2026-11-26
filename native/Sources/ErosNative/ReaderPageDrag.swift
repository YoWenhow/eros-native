import UIKit
import QuartzCore
import ErosCore
import ErosServices

/// The viewport moves one set of page views. Its horizontal pan owns input
/// even while the last turn is settling.
/// The inner reader scroll view owns pinch zoom and panning a zoomed page.
@MainActor final class ReaderPagingView<Reader: UIScrollView>: UIView {
    let reader: Reader
    let pager: ReaderHorizontalPager

    init(_ reader: Reader) {
        self.reader = reader
        pager = ReaderHorizontalPager(reader: reader)
        super.init(frame: .zero)
        addSubview(pager.viewport)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        pager.resize(to: bounds)
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        pager.performAccessibilityPageTurn(direction) || super.accessibilityScroll(direction)
    }
}

@MainActor final class ReaderHorizontalPager: NSObject, UIGestureRecognizerDelegate {
    let viewport = UIView()
    private let reader: UIScrollView
    private let current = UIView()
    private let arrival = ReaderPagePreviewSlot()
    private lazy var pagePan = UIPanGestureRecognizer(target: self, action: #selector(dragPage(_:)))
    private lazy var dismissPan = UIPanGestureRecognizer(target: self, action: #selector(dragDown(_:)))

    var preview: (ReaderSpread, Bool) async -> ReaderAdjacentPreview? = { _, _ in nil }
    var displayedPreview: () -> ReaderAdjacentPreview? = { nil }
    var commit: (Int) -> Bool = { _ in false }
    var dismiss: () -> Void = {}
    var interaction: () -> Void = {}
    var showsPreviewProgress = true

    private var track: ReaderPagingTrack?
    private var displayedPage: Int?
    private var liveIndex = 0
    private var reportedPage: Int?
    private var slots: [Int: ReaderPagePreviewSlot] = [:]
    private var reusableSlots: [ReaderPagePreviewSlot] = []
    private var nearby: ClosedRange<Int>?
    private var motion = ReaderPagingMotion()
    private var settlementFrames: CADisplayLink?
    private var active = false
    private var changingTrack = false
    private var zooming = false
    private var viewportSize = CGSize.zero
    private(set) var dismissalCommitted = false

    init(reader: UIScrollView) {
        self.reader = reader
        super.init()
        viewport.semanticContentAttribute = .forceLeftToRight
        viewport.backgroundColor = .systemBackground
        viewport.clipsToBounds = true
        viewport.addSubview(current)
        current.clipsToBounds = true
        current.addSubview(reader)
        current.addSubview(arrival)
        arrival.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        for pan in [pagePan, dismissPan] {
            pan.delegate = self
            pan.maximumNumberOfTouches = 1
            pan.cancelsTouchesInView = false
            viewport.addGestureRecognizer(pan)
        }
        syncGestures()
    }

    private var canInteract: Bool {
        active && !dismissalCommitted && displayedPage != nil && viewportSize.width > 0 && !zooming && reader.zoomScale <= 1.01
    }

    private var selectedIndex: Int {
        reportedPage.flatMap { track?.index(for: $0) } ?? liveIndex
    }

    /// A swipe update attaches the live reader to a slot at its existing scroll
    /// coordinate. A new pan can already be moving the viewport when this runs.
    func present(_ page: Int, track: ReaderPagingTrack?, active: Bool, invalidated: Bool) -> Bool {
        guard !dismissalCommitted else { return false }
        let resetting = self.active != active || self.track != track
        self.active = active
        if invalidated { clearPreviews() }
        if !resetting, displayedPage == page {
            if reportedPage == page { reportedPage = nil }
            if invalidated { refreshSlots() }
            syncGestures()
            return false
        }
        let index = track?.index(for: page) ?? 0
        let swipe = !resetting && reportedPage == page
        reportedPage = nil
        displayedPage = page
        if swipe {
            attachLiveReader(at: index)
        } else {
            interrupt()
            self.track = track
            liveIndex = index
            if !active { zooming = false }
            clearPreviews()
            layoutTrack(at: index)
        }
        syncGestures()
        return swipe
    }

    func contentDidUpdate(ready: Bool) {
        guard ready, active else { return }
        if arrival.prepared != nil { arrival.show(nil) }
        warmCachedPreviews()
    }

    func resize(to bounds: CGRect) {
        guard !dismissalCommitted, viewportSize != bounds.size || viewport.frame != bounds else { return }
        interrupt()
        viewportSize = bounds.size
        viewport.frame = bounds
        layoutTrack(at: selectedIndex)
        syncGestures()
    }

    func stop() {
        active = false
        reportedPage = nil
        if dismissalCommitted {
            stopSettlementFrames()
            for slot in slots.values { slot.task?.cancel() }
            return
        }
        interrupt()
        clearPreviews()
        layoutTrack(at: liveIndex)
        syncGestures()
    }

    func beginZoom() {
        guard !dismissalCommitted else { return }
        zooming = true
        interrupt()
        layoutTrack(at: selectedIndex)
        syncGestures()
    }

    func zoomDidChange() {
        syncGestures()
    }

    func endZoom() {
        zooming = false
        syncGestures()
    }

    private func syncGestures() {
        let enabled = canInteract
        if pagePan.isEnabled != enabled { pagePan.isEnabled = enabled }
        if dismissPan.isEnabled != enabled { dismissPan.isEnabled = enabled }
        let panEnabled = active && (zooming || reader.zoomScale > 1.01)
        if reader.panGestureRecognizer.isEnabled != panEnabled { reader.panGestureRecognizer.isEnabled = panEnabled }
    }

    private func interrupt() {
        changingTrack = true
        stopSettlementFrames()
        for pan in [pagePan, dismissPan] where pan.state == .began || pan.state == .changed {
            pan.isEnabled = false
            pan.isEnabled = true
        }
        current.layer.removeAllAnimations()
        current.transform = .identity
        changingTrack = false
    }

    private func layoutTrack(at index: Int) {
        changingTrack = true
        UIView.performWithoutAnimation {
            motion = ReaderPagingMotion(pageCount: track?.count ?? 0, index: index)
            placeLiveReader()
            for (index, slot) in slots { slot.frame = frame(at: index) }
            moveViewport()
            refreshSlots()
        }
        changingTrack = false
    }

    private func frame(at index: Int) -> CGRect {
        CGRect(x: CGFloat(index) * viewportSize.width, y: 0, width: viewportSize.width, height: viewportSize.height)
    }

    private func placeLiveReader() {
        current.frame = frame(at: liveIndex)
        if reader.frame != current.bounds { reader.frame = current.bounds }
        if arrival.frame != current.bounds { arrival.frame = current.bounds }
    }

    private func attachLiveReader(at index: Int) {
        let incoming = slots[index]?.prepared
        let previousIndex = liveIndex
        let outgoing = nearby?.contains(previousIndex) == true ? (arrival.prepared ?? displayedPreview()) : nil
        UIView.performWithoutAnimation {
            arrival.show(nil)
            recycleSlot(at: index)
            liveIndex = index
            placeLiveReader()
            refreshSlots(force: true)
            if let outgoing { slots[previousIndex]?.show(outgoing) }
            if incoming?.hasImage == true { arrival.show(incoming) }
        }
    }

    private func refreshSlots(force: Bool = false) {
        guard active, let need = track?.nearbyIndices(at: motion.position) else { return }
        guard force || nearby != need else { return }
        nearby = need
        for index in Array(slots.keys) where index == liveIndex || !need.contains(index) {
            recycleSlot(at: index)
        }
        for index in need where index != liveIndex && slots[index] == nil {
            let slot = reusableSlots.popLast() ?? ReaderPagePreviewSlot()
            slot.reset(for: index)
            slot.frame = frame(at: index)
            viewport.insertSubview(slot, belowSubview: current)
            slots[index] = slot
        }
    }

    private func recycleSlot(at index: Int) {
        guard let slot = slots.removeValue(forKey: index) else { return }
        slot.reset(for: nil)
        slot.removeFromSuperview()
        reusableSlots.append(slot)
    }

    private func clearPreviews() {
        for index in Array(slots.keys) { recycleSlot(at: index) }
        nearby = nil
        arrival.show(nil)
    }

    private func warmCachedPreviews() {
        for slot in slots.values { request(slot, cachedOnly: true) }
    }

    @objc private func dragPage(_ pan: UIPanGestureRecognizer) {
        guard canInteract, !changingTrack else { return }
        let space = viewport.superview
        let distance = Double(-pan.translation(in: space).x)
        let width = Double(viewportSize.width)
        let speed = Double(-pan.velocity(in: space).x)
        switch pan.state {
        case .began:
            stopSettlementFrames()
            motion.beginDrag()
            current.layer.removeAllAnimations()
            current.transform = .identity
            motion.drag(by: distance, viewportWidth: width)
            renderMotion()
            interaction()
        case .changed:
            motion.drag(by: distance, viewportWidth: width)
            renderMotion()
        case .ended:
            let page = motion.endDrag(distance: distance, velocity: speed, viewportWidth: width,
                                      at: CACurrentMediaTime(), reduceMotion: UIAccessibility.isReduceMotionEnabled)
            finishOrAnimate(page)
        case .cancelled, .failed:
            let page = motion.cancelDrag(at: CACurrentMediaTime(), reduceMotion: UIAccessibility.isReduceMotionEnabled)
            finishOrAnimate(page)
        default: break
        }
    }

    private func renderMotion() {
        moveViewport()
        refreshSlots()
        guard let visible = track?.visibleIndices(at: motion.position) else { return }
        for index in visible {
            if let slot = slots[index] { request(slot, cachedOnly: false) }
        }
    }

    private func moveViewport() {
        var bounds = viewport.bounds
        bounds.origin.x = CGFloat(motion.position) * viewportSize.width
        guard viewport.bounds != bounds else { return }
        UIView.performWithoutAnimation { viewport.bounds = bounds }
    }

    private func finishOrAnimate(_ index: Int?) {
        renderMotion()
        if let index {
            stopSettlementFrames()
            reportSettledPage(index)
            return
        }
        guard motion.isSettling, settlementFrames == nil else { return }
        let link = NativeScrollFrames.observe(self) { $0.advanceSettlement() }
        let maximum = Float(viewport.window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
        settlementFrames = link
    }

    private func advanceSettlement() {
        guard canInteract else { stopSettlementFrames(); return }
        let index = motion.advance(to: CACurrentMediaTime())
        renderMotion()
        if let index {
            stopSettlementFrames()
            reportSettledPage(index)
        }
    }

    private func stopSettlementFrames() {
        settlementFrames?.invalidate()
        settlementFrames = nil
    }

    private func reportSettledPage(_ index: Int) {
        guard canInteract, !changingTrack, let track else { return }
        let currentSelection = reportedPage ?? displayedPage
        guard currentSelection.flatMap({ track.index(for: $0) }) != index else { return }
        let page = index == liveIndex ? displayedPage : track.position(at: index)?.mainPage.value
        guard let page else { return }
        reportedPage = page
        if !commit(page) { reportedPage = nil }
    }

    func performAccessibilityPageTurn(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard canInteract, !motion.isDragging, let track else { return false }
        let forward = track.index(for: 0) == 0 ? 1 : -1
        let delta: Int
        switch direction {
        case .left: delta = -1
        case .right: delta = 1
        case .next: delta = forward
        case .previous: delta = -forward
        default: return false
        }
        guard let page = track.position(at: selectedIndex + delta)?.mainPage.value else { return false }
        interaction()
        return commit(page)
    }

    private func request(_ slot: ReaderPagePreviewSlot, cachedOnly: Bool) {
        guard let index = slot.index, slot.prepared == nil, !slot.requested,
              !cachedOnly || !slot.attemptedCache,
              let spread = track?.position(at: index)?.spread else { return }
        slot.attemptedCache = true
        slot.requested = !cachedOnly
        slot.task?.cancel()
        if !cachedOnly && showsPreviewProgress { slot.showProgress() }
        let load = preview
        slot.task = Task(priority: cachedOnly ? .utility : nil) { [weak self, weak slot] in
            let result = await load(spread, cachedOnly)
            guard !Task.isCancelled, let self, self.active, let slot, slot.index == index else { return }
            slot.task = nil
            if let result { slot.show(result) }
            else if !cachedOnly { slot.show(nil) }
        }
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard canInteract, let pan = gesture as? UIPanGestureRecognizer else { return false }
        let space = viewport.superview
        let velocity = pan.velocity(in: space)
        let direction = velocity == .zero ? pan.translation(in: space) : velocity
        if gesture === pagePan { return abs(direction.x) > abs(direction.y) }
        return !motion.isDragging && !motion.isSettling &&
            abs(motion.position - Double(liveIndex)) * Double(viewportSize.width) < 1 &&
            direction.y > abs(direction.x)
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        Self.acceptsTouch(touch.view)
    }

    private static func acceptsTouch(_ view: UIView?) -> Bool {
        var target = view
        while let view = target {
            if view is UIControl || view is ReaderPageStatusScrollView { return false }
            target = view.superview
        }
        return true
    }

    @objc private func dragDown(_ pan: UIPanGestureRecognizer) {
        guard !changingTrack, !dismissalCommitted else { return }
        if pan.state == .began { interaction() }
        let offset = pan.translation(in: viewport.superview)
        let y = max(0, offset.y)
        let scale = max(0.8, 1 - y / max(1, viewportSize.height) * 0.3)
        let transform = CGAffineTransform(translationX: offset.x * 0.2, y: y).scaledBy(x: scale, y: scale)
        switch pan.state {
        case .began, .changed:
            current.transform = transform
        case .ended where y > 110 || (y > 30 && pan.velocity(in: viewport.superview).y > 900):
            // Keep the release frame in place while the system moves the full-screen cover down.
            current.transform = transform
            dismissalCommitted = true
            dismiss()
        case .ended, .cancelled, .failed:
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.18,
                           delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.current.transform = .identity
            }
        default: break
        }
    }
}

private final class ReaderPagePreviewSlot: UIView {
    private(set) var index: Int?
    private(set) var prepared: ReaderAdjacentPreview?
    private let spinner = UIActivityIndicatorView(style: .medium)
    var task: Task<Void, Never>?
    var attemptedCache = false
    var requested = false

    init() {
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        clipsToBounds = true
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        addSubview(spinner)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reset(for index: Int?) {
        task?.cancel()
        task = nil
        self.index = index
        attemptedCache = false
        requested = false
        show(nil)
    }

    func showProgress() {
        spinner.startAnimating()
    }

    func show(_ preview: ReaderAdjacentPreview?) {
        prepared?.removeFromSuperview()
        prepared = preview
        if let preview {
            preview.frame = bounds
            preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(preview)
        }
        spinner.stopAnimating()
        isHidden = index == nil && preview == nil
    }
}

@MainActor final class ReaderAdjacentPreview: UIView {
    struct Page { let image: UIImage?; let ratio: CGFloat; let message: String? }
    private let ratios: [Double]
    let hasImage: Bool
    private var cells: [UIView] = []
    init(pages: [Page]) {
        ratios = pages.map { Double($0.ratio) }
        hasImage = pages.contains { $0.image != nil }
        super.init(frame: .zero)
        backgroundColor = .systemBackground; isUserInteractionEnabled = false; clipsToBounds = true
        for page in pages {
            if let image = page.image {
                let cell = UIImageView(image: image)
                cell.contentMode = .scaleAspectFit; cells.append(cell); addSubview(cell)
            } else {
                let cell = UILabel()
                cell.text = page.message ?? "正在加载…"; cell.textAlignment = .center
                cell.numberOfLines = 0; cell.textColor = .secondaryLabel
                cells.append(cell); addSubview(cell)
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let frames = SpreadReaderGeometry(width: bounds.width, height: bounds.height,
                                          aspectRatios: ratios).frames
        for (cell, frame) in zip(cells, frames) { cell.frame = frame }
    }
}
