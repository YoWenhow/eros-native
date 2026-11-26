import SwiftUI
import UIKit
import QuartzCore
import ErosCore
import ErosServices

/// One zoomable canvas with independent image consumers. Never composites bitmaps.
struct SpreadReaderAdapter: UIViewRepresentable {
    let model: ReaderViewModel
    let memory: ReaderImageMemory
    let position: SpreadPosition
    let retry: Int
    let active: Bool
    let previewRevision: UUID
    let onViewport: (ReaderPrefetchViewport) -> Void
    let onSelect: (Int) -> Void
    let onTap: () -> Void
    let pagingTrack: ReaderPagingTrack?
    let onSwipe: (Int) -> Bool
    let adjacent: (ReaderSpread, _ cachedOnly: Bool) async -> ReaderAdjacentPreview?
    let onDismiss: () -> Void
    let onInteraction: () -> Void
    let onProgressFailure: (Bool) -> Void
    let autoAdvance: ReaderAutoAdvanceSession
    let presentation: UUID
    let onZoomChanged: (Bool) -> Void
    func makeUIView(context: Context) -> ReaderPagingView<SpreadReaderScrollView> {
        let reader = SpreadReaderScrollView(model: model, memory: memory, autoAdvance: autoAdvance)
        let container = ReaderPagingView(reader)
        let pager = container.pager
        reader.pager = pager
        pager.showsPreviewProgress = !model.isOffline
        pager.displayedPreview = { [weak reader] in reader?.makeDisplayedPreview() }
        return container
    }
    func updateUIView(_ container: ReaderPagingView<SpreadReaderScrollView>, context: Context) {
        let view = container.reader
        let pager = container.pager
        guard !pager.dismissalCommitted else { return }
        view.onSelect = onSelect; view.onTap = onTap; view.onProgressFailure = onProgressFailure
        view.onZoomChanged = onZoomChanged; view.onViewport = onViewport
        pager.commit = onSwipe; pager.preview = adjacent
        pager.dismiss = onDismiss; pager.interaction = onInteraction
        view.update(position: position, mode: model.mode, retry: retry, active: active,
            presentation: presentation, previewRevision: previewRevision, pagingTrack: pagingTrack)
    }
    static func dismantleUIView(_ container: ReaderPagingView<SpreadReaderScrollView>, coordinator: ()) {
        container.reader.stop()
    }
}

@MainActor final class SpreadReaderScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let model: ReaderViewModel
    private let memory: ReaderImageMemory
    private let canvas = UIView()
    private let autoAdvance: ReaderAutoAdvanceSession
    private var presentation = UUID()
    private var tiles: [Int: SpreadReaderTile] = [:]
    private var order: [Int] = []
    private var selected = -1
    private var mode = ReadingMode.leftToRight
    private var lastRetry = 0
    private var active = false
    private var fittedSize = CGSize.zero
    private var outgoing: UIView?
    weak var pager: ReaderHorizontalPager?
    private var previewRevision: UUID?
    private let pageDuration = 0.24
    var onSelect: (Int) -> Void = { _ in }
    var onTap: () -> Void = {}
    var onProgressFailure: (Bool) -> Void = { _ in }
    var onZoomChanged: (Bool) -> Void = { _ in }
    var onViewport: (ReaderPrefetchViewport) -> Void = { _ in }
    init(model: ReaderViewModel, memory: ReaderImageMemory, autoAdvance: ReaderAutoAdvanceSession) {
        self.model = model; self.memory = memory; self.autoAdvance = autoAdvance
        super.init(frame: .zero)
        delegate = self; backgroundColor = .systemBackground; canvas.backgroundColor = .systemBackground
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        minimumZoomScale = 1; maximumZoomScale = 6
        addSubview(canvas)
        let single = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2; single.require(toFail: double)
        single.delegate = self; double.delegate = self
        addGestureRecognizer(single); addGestureRecognizer(double)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(position: SpreadPosition, mode: ReadingMode, retry: Int, active: Bool,
                presentation: UUID, previewRevision: UUID, pagingTrack: ReaderPagingTrack?) {
        let discardPreview = self.previewRevision != nil && self.previewRevision != previewRevision
        self.previewRevision = previewRevision
        let presentationChanged = self.presentation != presentation
        self.presentation = presentation
        let newOrder = position.spread.displayPages.map(\.value)
        let changed = order != newOrder || self.mode != mode
        let focusChanged = selected != position.mainPage.value
        let resumed = active && !self.active
        let settled = pager?.present(position.mainPage.value, track: pagingTrack, active: active,
            invalidated: discardPreview || self.mode != mode) == true
        let oldFirst = order.min(), newFirst = newOrder.min()
        let turn = active && self.active && !settled && !discardPreview && self.mode == mode &&
            !order.isEmpty && Set(order).isDisjoint(with: newOrder)
        let entryShift: CGFloat? = turn && !UIAccessibility.isReduceMotionEnabled
            ? (((newFirst ?? 0) > (oldFirst ?? 0)) != (mode == .rightToLeft) ? bounds.width : -bounds.width) : nil
        if changed { cancelPagingAnimations() }
        if entryShift != nil { captureOutgoing() }
        if self.active && !active { saveProgress() }
        self.active = active; self.mode = mode; selected = position.mainPage.value
        if changed {
            for key in Array(tiles.keys) where !newOrder.contains(key) {
                tiles[key]?.stop(); tiles[key]?.removeFromSuperview(); tiles.removeValue(forKey: key)
            }
            order = newOrder
            setZoomScale(1, animated: false); fittedSize = .zero
        }
        for index in order where tiles[index] == nil {
            let tile = SpreadReaderTile(index: index)
            tile.retryAction = { [weak self] in self?.retryPage(index) }
            tile.selectAction = { [weak self] in self?.select(index) }
            tiles[index] = tile; canvas.addSubview(tile)
        }
        if !active {
            cancelPagingAnimations()
            for tile in tiles.values { tile.stop() }
            lastRetry = retry; return
        }
        for index in order {
            guard let tile = tiles[index] else { continue }
            tile.loader?.mode = mode
            if resumed || presentationChanged || (tile.task == nil && tile.picture.image == nil && !tile.failed) { start(tile, retry: false) }
        }
        if retry != lastRetry {
            let requested = retry > lastRetry
            lastRetry = retry
            if requested { retryPage(selected) }
        }
        if changed || focusChanged || resumed { saveProgress() }
        setNeedsLayout(); layoutIfNeeded()
        if discardPreview { cancelPagingAnimations() }
        else if let entryShift { animateTurn(entryShift: entryShift) }
        publishViewport()
        Task { @MainActor [weak self] in
            guard let self, self.window != nil else { return }; self.onZoomChanged(self.zoomScale > 1.01)
        }
    }
    fileprivate func makeDisplayedPreview() -> ReaderAdjacentPreview? {
        let pages = order.map { index -> ReaderAdjacentPreview.Page in
            let image = tiles[index]?.picture.image
            let ratio = image.map { $0.size.width / max(1, $0.size.height) }
                ?? CGFloat(1 / (memory.aspectRatios[index] ?? 1.5))
            let message = tiles[index]?.imageBlockOverlay == nil ? tiles[index]?.message.text : "已屏蔽"
            return .init(image: image, ratio: ratio, message: message)
        }
        guard pages.contains(where: { $0.image != nil }) else { return nil }
        return ReaderAdjacentPreview(pages: pages)
    }

    private func captureOutgoing() {
        let leaving = UIView(frame: bounds)
        leaving.backgroundColor = .systemBackground; leaving.clipsToBounds = true
        leaving.isUserInteractionEnabled = false; leaving.accessibilityElementsHidden = true
        for index in order {
            guard let tile = tiles[index], let image = tile.picture.image else { continue }
            let picture = UIImageView(image: image)
            picture.contentMode = .scaleAspectFit
            // Reuse decoded images and their actual current frames; no screenshot bitmap.
            picture.frame = tile.picture.convert(tile.picture.bounds, to: self).offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            leaving.addSubview(picture)
        }
        addSubview(leaving); outgoing = leaving
    }
    private func animateTurn(entryShift: CGFloat) {
        func animation(from: CGFloat, to: CGFloat) -> CABasicAnimation {
            let value = CABasicAnimation(keyPath: "transform.translation.x")
            value.fromValue = from; value.toValue = to; value.duration = pageDuration
            value.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            let maximum = Float(window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
            value.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
            value.isAdditive = true
            return value
        }
        canvas.layer.add(animation(from: entryShift, to: 0), forKey: "spreadEnter")
        if let leaving = outgoing {
            leaving.frame = bounds
            let exit = animation(from: 0, to: -entryShift)
            exit.fillMode = .forwards; exit.isRemovedOnCompletion = false
            leaving.layer.add(exit, forKey: "spreadExit")
            DispatchQueue.main.asyncAfter(deadline: .now() + pageDuration) { [weak self, weak leaving] in
                leaving?.removeFromSuperview()
                if self?.outgoing === leaving { self?.outgoing = nil }
            }
        }
    }
    private func cancelPagingAnimations() {
        outgoing?.removeFromSuperview(); outgoing = nil
        canvas.layer.removeAnimation(forKey: "spreadEnter")
    }
    private func select(_ index: Int) {
        guard active, order.contains(index) else { return }
        selected = index; onSelect(index); saveProgress()
    }
    private func retryPage(_ index: Int) {
        guard active, let tile = tiles[index] else { return }
        autoAdvance.pause(.manualNavigation)
        // Retrying the other half does not move the reading anchor or reload its peer.
        if let page = try? PageIndex(index) { autoAdvance.loading(page, presentation: presentation) }
        start(tile, retry: true)
        publishViewport()
    }
    private func start(_ tile: SpreadReaderTile, retry: Bool) {
        let retainedImage = tile.picture.image
        tile.stop(); tile.failed = false
        let index = tile.index
        guard let page = try? PageIndex(index) else { return }
        let loader = model.pageModel(index: page)
        loader.mode = mode; tile.loader = loader
        // Validate even a bitmap cache hit before exposing it after foregrounding.
        tile.picture.image = retry ? nil : retainedImage
        tile.message.isHidden = true
        tile.retry.isHidden = true
        if tile.picture.image == nil, !model.isOffline || retry { tile.showTransfer(loader) }
        let ticket = UUID(); tile.ticket = ticket
        let presentation = self.presentation
        tile.task = Task { [weak self, weak tile, weak memory = memory] in
            guard let memory else { return }
            let image = await memory.load(page, using: loader, continuous: false, retry: retry)
            loader.releaseCompressedBytes()
            guard !Task.isCancelled, let self, self.active, let tile, tile.ticket == ticket,
                  self.tiles[index] === tile else { return }
            tile.task = nil;tile.hideTransfer()
            if let image {
                tile.picture.image = image; tile.message.isHidden = true
                self.memory.insert(image, loader: loader, index: index, continuous: false)
                if self.memory.isBlocked(loader) {
                    tile.picture.image = nil
                    let overlay = ReaderImageBlockOverlay(loader: loader, memory: self.memory) { [weak self, weak tile] in
                        tile?.imageBlockOverlay?.removeFromSuperview(); tile?.imageBlockOverlay = nil
                        tile?.picture.image = image
                        self?.autoAdvance.readable(page, presentation: presentation)
                    }
                    tile.imageBlockOverlay = overlay; tile.addSubview(overlay)
                    self.autoAdvance.pause(.modeChanged)
                } else { self.autoAdvance.readable(page, presentation: presentation) }
                if self.selected == index { self.saveProgress() }
            } else {
                tile.failed = true; tile.picture.image = nil; tile.message.isHidden = false
                self.autoAdvance.failed(page, presentation: presentation, error: loader.error)
                tile.message.text = "第 \(index + 1) 页\n" + (loader.imageFailureCode ?? loader.parseFailureCode ?? loader.error.map(readerError) ?? "加载未完成，请重试")
                tile.retry.isHidden = false
            }
            tile.setNeedsLayout()
            self.setNeedsLayout() // Late dimensions refit adjacent edges without resetting group zoom.
            self.publishViewport()
        }
    }
    private func publishViewport() {
        guard active else { return }
        let ready = !order.isEmpty && order.allSatisfy { index in
            guard let tile = tiles[index] else { return false }
            return tile.task == nil && (tile.picture.image != nil || tile.imageBlockOverlay != nil)
        }
        pager?.contentDidUpdate(ready: ready || order.allSatisfy { index in
            guard let tile = tiles[index] else { return false }
            return tile.task == nil && (tile.picture.image != nil || tile.imageBlockOverlay != nil || tile.failed)
        })
        onViewport(ReaderPrefetchViewport(pages: order.sorted(), ready: ready))
    }
    private func saveProgress() {
        guard active, let tile = tiles[selected], (tile.picture.image != nil || tile.loader?.blockedImage != nil),
              let loader = tile.loader, let page = try? PageIndex(selected) else { return }
        loader.mode = mode
        guard let progress = loader.captureDisplayedProgress(index: page) else { return }
        Task { [weak self] in
            await loader.displayed(progress)
            guard let self, self.active, self.selected == page.value, self.tiles[page.value]?.loader === loader else { return }
            self.onProgressFailure(loader.progressFailed)
        }
    }
    func stop() {
        saveProgress()
        active = false; pager?.stop(); cancelPagingAnimations()
        for tile in tiles.values { tile.stop() }
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerCanvas()
        pager?.zoomDidChange()
        Task { @MainActor [weak self] in
            guard let self, self.window != nil else { return }; self.onZoomChanged(self.zoomScale > 1.01)
        }
    }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        if let pinch = scrollView.pinchGestureRecognizer, pinch.state == .began || pinch.state == .changed {
            pager?.beginZoom()
            autoAdvance.setBlocker(.zoom, active: true); onZoomChanged(true)
        }
        cancelPagingAnimations()
    }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        pager?.endZoom()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, !order.isEmpty else { return }
        if fittedSize != bounds.size {
            if fittedSize != .zero { cancelPagingAnimations() }
            fittedSize = bounds.size; setZoomScale(1, animated: false)
            canvas.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size; contentOffset = .zero
        }
        let ratios = order.map { index -> Double in
            if let image = tiles[index]?.picture.image { return image.size.width / max(1, image.size.height) }
            return 1 / (memory.aspectRatios[index] ?? 1.5)
        }
        let geometry = SpreadReaderGeometry(width: fittedSize.width, height: fittedSize.height, aspectRatios: ratios)
        for (column, index) in order.enumerated() where column < geometry.frames.count {
            var frame = geometry.frames[column]
            if tiles[index]?.failed == true {
                // Grow only this column's error canvas, not the peer image or
                // the spread's page/zoom geometry. Retry restores the image fit.
                frame.size.height = min(fittedSize.height, max(160, frame.height))
                frame.origin.y = (fittedSize.height - frame.height) / 2
            }
            tiles[index]?.frame = frame
        }
        centerCanvas()
    }
    private func centerCanvas() { canvas.center = CGPoint(x: max(bounds.width, contentSize.width) / 2, y: max(bounds.height, contentSize.height) / 2) }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var target = touch.view
        while let view = target { if view is UIControl || view is ReaderPageStatusScrollView || view is ReaderImageBlockOverlay { return false }; target = view.superview }
        return true
    }
    private func select(at point: CGPoint) {
        if let index = order.first(where: { tiles[$0]?.frame.contains(point) == true }) { select(index) }
    }
    @objc private func tapped(_ recognizer: UITapGestureRecognizer) { select(at: recognizer.location(in: canvas)); onTap() }
    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        pager?.beginZoom()
        autoAdvance.setBlocker(.zoom, active: true); onZoomChanged(true)
        let point = recognizer.location(in: canvas); select(at: point)
        if zoomScale > 1.01 { setZoomScale(1, animated: !UIAccessibility.isReduceMotionEnabled); return }
        let width = bounds.width / 3, height = bounds.height / 3
        zoom(to: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height), animated: !UIAccessibility.isReduceMotionEnabled)
    }
}

@MainActor private final class SpreadReaderTile: UIView {
    let index: Int
    var transfer:ReaderTransferOverlay?
    var imageBlockOverlay: ReaderImageBlockOverlay?
    let picture = UIImageView()
    let message = UILabel()
    private let statusScroll = ReaderPageStatusScrollView(frame: .zero)
    let retry = UIButton(type: .system)
    var loader: ReaderViewModel?
    var task: Task<Void, Never>?
    var ticket = UUID()
    var failed = false
    var retryAction: () -> Void = {}
    var selectAction: () -> Void = {}
    init(index: Int) {
        self.index = index; super.init(frame: .zero)
        clipsToBounds = true; backgroundColor = .systemBackground
        picture.contentMode = .scaleAspectFit
        picture.isAccessibilityElement = true; picture.accessibilityLabel = "第 \(index + 1) 页图片"
        picture.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "设为当前阅读页", target: self, selector: #selector(selectPage))]
        message.numberOfLines = 0; message.textAlignment = .center; message.textColor = .secondaryLabel
        message.font = .preferredFont(forTextStyle: .body); message.adjustsFontForContentSizeCategory = true
        retry.setTitle("重试本页", for: .normal); retry.accessibilityLabel = "重试第 \(index + 1) 页"
        retry.addTarget(self, action: #selector(retryPage), for: .touchUpInside)
        statusScroll.contentInsetAdjustmentBehavior = .never
        statusScroll.addSubview(message)
        addSubview(picture); addSubview(statusScroll); addSubview(retry)
    }
    func showTransfer(_ loader:ReaderViewModel) {
        hideTransfer()
        guard let page=try? PageIndex(index) else { return }
        let overlay=ReaderTransferOverlay(owner:.reader(loader.document.scope,loader.document.reference.key.galleryID,page))
        transfer=overlay;addSubview(overlay);message.isHidden=true;setNeedsLayout()
    }
    func hideTransfer() { transfer?.removeFromSuperview();transfer=nil }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func retryPage() { retryAction() }
    @objc private func selectPage() -> Bool { selectAction(); return true }
    override func layoutSubviews() {
        super.layoutSubviews(); picture.frame = bounds
        imageBlockOverlay?.frame = bounds
        transfer?.frame=CGRect(x:12,y:max(0,(bounds.height-90)/2),width:max(0,bounds.width-24),height:90)
        ReaderPageStatusLayout.apply(bounds: bounds, message: message, scroll: statusScroll, retry: retry)
    }
    func stop() { hideTransfer(); imageBlockOverlay?.removeFromSuperview(); imageBlockOverlay = nil; ticket = UUID(); task?.cancel(); task = nil; loader?.stop(); loader = nil }
}
