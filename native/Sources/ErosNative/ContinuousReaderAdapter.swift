import SwiftUI
import UIKit
import ErosCore
import ErosServices

struct ContinuousReaderAdapter: UIViewRepresentable {
    let model: ReaderViewModel
    let memory: ReaderImageMemory
    let selected: Int
    let startFraction: Double
    let retry: Int
    let active: Bool
    let onSelect: (Int) -> Void
    let onTap: () -> Void
    let onViewport: (ReaderPrefetchViewport) -> Void
    func makeUIView(context: Context) -> ContinuousReaderScrollView { ContinuousReaderScrollView(model: model, memory: memory, selected: selected, startFraction: startFraction) }
    func updateUIView(_ view: ContinuousReaderScrollView, context: Context) {
        view.onSelect = onSelect; view.onTap = onTap; view.onViewport = onViewport
        view.update(selected: selected, retry: retry, active: active)
    }
    static func dismantleUIView(_ view: ContinuousReaderScrollView, coordinator: ()) { view.stop() }
}

@MainActor final class ContinuousReaderScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let model: ReaderViewModel
    private let memory: ReaderImageMemory
    private var geometry = VerticalReaderGeometry(count: 0, width: 1)
    private var ratios: [Int: Double] = [:]
    private var tiles: [Int: ReaderStripTile] = [:]
    private var selected = 0
    private var lastInput = -1
    private var lastRetry = 0
    private var active = false
    private var updating = false
    private var initialJump: Int?
    private var explicitFocus: Int?
    private var initialFraction: Double?
    private var saveTask: Task<Void, Never>?
    private var lastViewport: ReaderPrefetchViewport?
    private var visibleRange: ClosedRange<Int>? {
        geometry.visible(from: contentOffset.y, to: contentOffset.y + bounds.height)
    }
    var onSelect: (Int) -> Void = { _ in }
    var onTap: () -> Void = {}
    var onViewport: (ReaderPrefetchViewport) -> Void = { _ in }
    init(model: ReaderViewModel, memory: ReaderImageMemory, selected: Int, startFraction: Double) {
        self.model = model; self.memory = memory; ratios = memory.aspectRatios
        self.selected = selected; lastInput = selected; initialJump = selected
        initialFraction = startFraction
        super.init(frame: .zero)
        delegate = self; backgroundColor = .systemBackground
        contentInsetAdjustmentBehavior = .never; alwaysBounceVertical = true
        showsHorizontalScrollIndicator = false
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.delegate = self; addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func tapped() { onTap() }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var target = touch.view
        while let view = target { if view is UIControl || view is ReaderPageStatusScrollView || view is ReaderImageBlockOverlay { return false }; target = view.superview }
        return true
    }
    func update(selected: Int, retry: Int, active: Bool) {
        let resumed = active && !self.active
        if !active {
            if self.active { saveProgress() }
            self.active = false
            for tile in tiles.values { tile.pause() }
            lastViewport = nil
            return
        }
        self.active = true
        if selected != lastInput {
            lastInput = selected; self.selected = selected; initialJump = selected
            explicitFocus = selected
            reflow(jump: selected)
        } else if initialJump != nil || geometry.count != model.count { reflow(jump: initialJump ?? selected) }
        if retry != lastRetry {
            lastRetry = retry
            memory.remove(selected, continuous: true)
            if let tile = tiles[selected] { tile.cancel(); start(tile, index: selected, retry: true) }
        }
        if resumed { refresh() }
        publishViewport(force: true)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard active, bounds.width > 0, bounds.height > 0, model.count > 0, !updating else { return }
        if initialJump != nil || abs(geometry.width - bounds.width) > 0.5 || geometry.count != model.count {
            reflow(jump: initialJump ?? explicitFocus)
        } else { refresh() }
    }
    private func reflow(jump: Int? = nil) {
        guard active, bounds.width > 0, bounds.height > 0, model.count > 0, !updating else { return }
        let anchor = geometry.anchor(at: contentOffset.y)
        let targetPage = jump ?? initialJump
        updating = true
        geometry = VerticalReaderGeometry(count: model.count, width: bounds.width, ratios: ratios)
        contentSize = CGSize(width: bounds.width, height: geometry.totalHeight)
        let y = targetPage.map { geometry.offset(index: $0, fraction: initialFraction ?? 0) } ?? geometry.offset(index: anchor.index, fraction: anchor.fraction)
        if targetPage != nil { initialFraction = nil; initialJump = nil }
        let target = min(max(0, y), max(0, contentSize.height - bounds.height))
        if abs(contentOffset.y - target) > 0.5 { contentOffset = CGPoint(x: 0, y: target) }
        updating = false
        refresh()
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { explicitFocus = nil }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { if !updating { refresh() } }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishScroll() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { finishScroll() } }
    private func finishScroll() {
        saveProgress()
    }
    private func refresh() {
        guard active, !updating, initialJump == nil, bounds.width > 0, bounds.height > 0 else { return }
        let visible = visibleRange
        let anchor = geometry.anchor(at: max(0, contentOffset.y) + min(80, bounds.height / 4)).index
        // At the end, the scroll offset can be clamped above the chosen short page.
        // Keep that visible page selected until the user starts scrolling again.
        let focus = visible.map { min($0.upperBound, max($0.lowerBound, explicitFocus ?? anchor)) } ?? selected
        if selected != focus {
            selected = focus; lastInput = focus
            Task { @MainActor [weak self] in guard let self, self.active, self.selected == focus else { return }; self.onSelect(focus) }
            saveTask?.cancel()
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }; self?.saveProgress()
            }
        }
        var wanted = geometry.retained(around: focus)
        if let visible { wanted.formUnion(visible) }
        for index in Array(tiles.keys) where !wanted.contains(index) {
            tiles[index]?.cancel(); tiles[index]?.removeFromSuperview(); tiles.removeValue(forKey: index)
        }
        for index in wanted.sorted(by: { abs($0 - focus) == abs($1 - focus) ? $0 < $1 : abs($0 - focus) < abs($1 - focus) }) {
            let tile: ReaderStripTile
            if let existing = tiles[index] { tile = existing }
            else { tile = ReaderStripTile(index: index); tiles[index] = tile; addSubview(tile) }
            tile.frame = CGRect(x: 0, y: geometry.offsets[index], width: bounds.width, height: geometry.heights[index])
            let top = min(max(0, contentOffset.y - tile.frame.minY + 90), max(0, tile.bounds.height - 300))
            tile.imageBlockOverlay?.setControlRegion(CGRect(x: 0, y: top, width: tile.bounds.width, height: min(300, tile.bounds.height)))
            if visible?.contains(index) == true {
                if tile.needsLoad { start(tile, index: index) }
            } else if tile.loader != nil {
                tile.cancel()
            }
        }
        publishViewport()
    }

    private func publishViewport(force: Bool = false) {
        guard active, !updating, initialJump == nil else { return }
        let pages = visibleRange.map(Array.init) ?? []
        let ready = !pages.isEmpty && pages.allSatisfy { tiles[$0]?.isReady == true }
        let value = ReaderPrefetchViewport(pages: pages, ready: ready)
        guard force || value != lastViewport else { return }
        lastViewport = value
        onViewport(value)
    }

    private func start(_ tile: ReaderStripTile, index: Int, retry: Bool = false) {
        guard active, visibleRange?.contains(index) == true, let page = try? PageIndex(index) else { return }
        tile.failed = false
        tile.imageBlockOverlay?.removeFromSuperview(); tile.imageBlockOverlay = nil
        let loader = model.pageModel(index: page); loader.mode = .vertical
        tile.loader = loader
        tile.message.isHidden = true
        tile.retry.isHidden = true
        if !model.isOffline || retry { tile.showTransfer(loader) }
        tile.retryAction = { [weak self, weak tile] in
            guard let self, let tile else { return }
            tile.cancel()
            self.start(tile, index: index, retry: true)
            self.publishViewport()
        }
        tile.task = Task { [weak self, weak tile, weak memory = memory] in
            guard let memory else { return }
            let image = await memory.load(page, using: loader, continuous: true, retry: retry)
            loader.releaseCompressedBytes()
            guard !Task.isCancelled, let self, self.active, let tile, tile.loader === loader,
                  self.visibleRange?.contains(index) == true else { return }
            tile.task = nil
            tile.hideTransfer()
            if let image {
                tile.picture.image = image; tile.message.isHidden = true
                self.memory.insert(image, loader: loader, index: index, continuous: true)
                if self.memory.isBlocked(loader) {
                    tile.picture.image = nil
                    let overlay = ReaderImageBlockOverlay(loader: loader, memory: self.memory) { [weak tile] in
                        tile?.imageBlockOverlay?.removeFromSuperview(); tile?.imageBlockOverlay = nil
                        tile?.picture.image = image
                    }
                    tile.imageBlockOverlay = overlay; tile.addSubview(overlay)
                    let top = min(max(0, self.contentOffset.y - tile.frame.minY + 90), max(0, tile.bounds.height - 300))
                    overlay.setControlRegion(CGRect(x: 0, y: top, width: tile.bounds.width, height: min(300, tile.bounds.height)))
                    tile.setNeedsLayout()
                }
                let ratio = image.size.height / max(1, image.size.width)
                if abs((self.ratios[index] ?? 1.5) - ratio) > 0.001 {
                    self.ratios[index] = ratio
                    self.reflow(jump: self.explicitFocus)
                }
                if self.selected == index { self.saveProgress() }
            } else {
                tile.failed = true
                tile.message.isHidden=false
                tile.message.text = "第 \(index + 1) 页\n" + (loader.imageFailureCode ?? loader.parseFailureCode ?? loader.error.map(readerError) ?? "加载未完成")
                tile.retry.isHidden = false
            }
            tile.setNeedsLayout()
            self.publishViewport()
        }
    }
    private func saveProgress() {
        guard let tile = tiles[selected], (tile.picture.image != nil || tile.loader?.blockedImage != nil), let loader = tile.loader,
              let page = try? PageIndex(selected) else { return }
        let location = geometry.anchor(at: max(0, contentOffset.y))
        let fraction = location.index == selected ? location.fraction : 0
        guard let value = try? UnitFraction(fraction),
              let progress = loader.captureDisplayedProgress(index: page, fraction: value) else { return }
        Task { [weak tile] in
            await loader.displayed(progress)
            if let tile, tile.loader === loader, loader.progressFailed {
                tile.message.text = "阅读进度保存失败，请重试"; tile.message.isHidden = false
                tile.setNeedsLayout()
            }
        }
    }
    private func cancelTiles() { for tile in tiles.values { tile.cancel() } }
    func stop() {
        saveProgress()
        active = false
        saveTask?.cancel()
        cancelTiles()
    }
}

@MainActor private final class ReaderStripTile: UIView {
    var transfer:ReaderTransferOverlay?
    var imageBlockOverlay: ReaderImageBlockOverlay?
    let picture = UIImageView()
    let message = UILabel()
    private let statusScroll = ReaderPageStatusScrollView(frame: .zero)
    let retry = UIButton(type: .system)
    var retryAction: () -> Void = {}
    var task: Task<Void, Never>?
    var loader: ReaderViewModel?
    var failed = false
    var isReady: Bool { task == nil && (picture.image != nil || imageBlockOverlay != nil) }
    var needsLoad: Bool { task == nil && !failed && !isReady }
    let index: Int
    init(index: Int) {
        self.index = index
        super.init(frame: .zero)
        backgroundColor = .systemBackground; clipsToBounds = true
        picture.contentMode = .scaleAspectFit
        picture.isAccessibilityElement = true
        picture.accessibilityLabel = "第 \(index + 1) 页图片"
        message.textAlignment = .center; message.numberOfLines = 0; message.textColor = .secondaryLabel
        message.font = .preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        retry.accessibilityLabel = "重试第 \(index + 1) 页"
        retry.setTitle("重试本页", for: .normal); retry.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        statusScroll.contentInsetAdjustmentBehavior = .never
        statusScroll.addSubview(message)
        addSubview(picture); addSubview(statusScroll); addSubview(retry)
        cancel()
    }
    func showTransfer(_ loader:ReaderViewModel) {
        hideTransfer()
        guard let page=try? PageIndex(index) else { return }
        let overlay=ReaderTransferOverlay(owner:.reader(loader.document.scope,loader.document.reference.key.galleryID,page))
        transfer=overlay;addSubview(overlay);message.isHidden=true;setNeedsLayout()
    }
    func hideTransfer() { transfer?.removeFromSuperview();transfer=nil }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func retryTapped() { retryAction() }
    override func layoutSubviews() {
        super.layoutSubviews(); picture.frame = bounds
        imageBlockOverlay?.frame = bounds
        transfer?.frame=CGRect(x:12,y:max(0,(bounds.height-90)/2),width:max(0,bounds.width-24),height:90)
        ReaderPageStatusLayout.apply(bounds: bounds, message: message, scroll: statusScroll, retry: retry)
    }
    func cancel() {
        hideTransfer()
        imageBlockOverlay?.removeFromSuperview(); imageBlockOverlay = nil
        task?.cancel(); task = nil; loader = nil; picture.image = nil
        failed = false
        message.text = "第 \(index + 1) 页"; message.isHidden = false; retry.isHidden = true
    }
    func pause() {
        hideTransfer()
        task?.cancel(); task = nil
        if !isReady { loader = nil; failed = false }
    }
}
