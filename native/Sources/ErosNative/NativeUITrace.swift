#if DEBUG
import SwiftUI
import UIKit

/// Explicitly enabled by a launch argument; no text, gallery IDs, or credentials are recorded.
@MainActor final class NativeUITrace: NSObject {
    static let shared = NativeUITrace()
    private var timer: CADisplayLink?
    private var output: FileHandle?
    private var bytes = 0
    private var lastSample: CFTimeInterval = 0
    private var lastState = Data()
    private var attached = Set<ObjectIdentifier>()
    private var pendingEvents: [[String: Any]] = []

    func startIfRequested() {
        guard timer == nil, ProcessInfo.processInfo.arguments.contains("--eros-ui-trace") else { return }
        do {
            let folder = URL.cachesDirectory.appending(path: "ErosUITrace")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: "trace.jsonl")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            output = try FileHandle(forWritingTo: file)
            write(["event": "start", "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "",
                   "system": UIDevice.current.systemVersion])
            let link = CADisplayLink(target: self, selector: #selector(sample))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            timer = link
        } catch { output = nil }
    }

    func event(_ name: String, _ fields: [String: Any] = [:]) {
        guard output != nil else { return }
        pendingEvents.append(["event": name, "fields": fields])
    }

    private func id(_ object: AnyObject?) -> String {
        object.map { String(describing: ObjectIdentifier($0)) } ?? ""
    }
    private func name(_ object: AnyObject) -> String { String(describing: type(of: object)) }
    private func rect(_ value: CGRect) -> [CGFloat] { [value.minX, value.minY, value.width, value.height] }
    private func insets(_ value: UIEdgeInsets) -> [CGFloat] { [value.top, value.left, value.bottom, value.right] }
    private func transform(_ layer: CALayer) -> [CGFloat] {
        let t = layer.transform
        return [t.m11, t.m12, t.m21, t.m22, t.m41, t.m42]
    }
    private func view(_ v: UIView) -> [String: Any] {
        var effectiveAlpha: CGFloat = 1
        var parent: UIView? = v
        while let candidate = parent {
            effectiveAlpha *= candidate.isHidden ? 0 : candidate.alpha
            parent = candidate.superview
        }
        return ["effectiveAlpha": effectiveAlpha, "id": id(v), "type": name(v), "frame": rect(v.convert(v.bounds, to: nil)),
         "alpha": v.alpha, "hidden": v.isHidden, "interaction": v.isUserInteractionEnabled,
         "presentation": v.layer.presentation().map { rect($0.frame) } ?? [],
         "presentationWindow": v.layer.presentation().map { layer in
             rect(layer.convert(layer.bounds, to: v.window?.layer.presentation()))
         } ?? [], "transform": transform(v.layer),
         "presentationTransform": v.layer.presentation().map(transform) ?? [],
         "safe": insets(v.safeAreaInsets)]
    }
    private func knownTitle(_ title: String?) -> String {
        guard let title else { return "" }
        return ["资料库", "搜索", "画廊详情", "下载", "全部下载", "未完成", "评论"].contains(title) ? title : "other"
    }
    private func page(_ c: UIViewController) -> [String: Any] {
        var row: [String: Any] = ["id": id(c), "type": name(c), "title": knownTitle(c.navigationItem.title ?? c.title),
            "loaded": c.isViewLoaded, "additional": insets(c.additionalSafeAreaInsets),
            "topScroll": id(c.contentScrollView(for: .top)), "disappearing": c.isMovingFromParent,
            "definesContext": c.definesPresentationContext, "preferredTransition": c.preferredTransition.map { String(describing: $0) } ?? "nil", "largeTitleMode": c.navigationItem.largeTitleDisplayMode.rawValue]
        if let v = c.viewIfLoaded { row["view"] = view(v) }
        if let s = c.navigationItem.searchController {
            row["search"] = ["id": id(s), "active": s.isActive,
                "presenting": id(s.presentingViewController), "presented": id(s.presentedViewController),
                "field": view(s.searchBar.searchTextField),
                "focused": s.searchBar.searchTextField.isFirstResponder,
                "textLength": s.searchBar.searchTextField.text?.count ?? 0,
                "bar": view(s.searchBar), "toolbarIntegration": c.navigationItem.searchBarPlacementAllowsToolbarIntegration]
        }
        return row
    }

    @objc private func sample(_ link: CADisplayLink) {
        guard output != nil else { return }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).filter { !$0.isHidden && $0.windowLevel == .normal }
        var controllers: [UIViewController] = []
        func walk(_ c: UIViewController) {
            controllers.append(c)
            c.children.forEach(walk)
            if let presented = c.presentedViewController { walk(presented) }
        }
        for window in windows {
            if attached.insert(ObjectIdentifier(window)).inserted {
                let observer = NativeUITraceTouch()
                observer.cancelsTouchesInView = false
                observer.delaysTouchesBegan = false
                observer.delaysTouchesEnded = false
                window.addGestureRecognizer(observer)
            }
            if let c = window.rootViewController { walk(c) }
        }
        let navigations = controllers.compactMap { $0 as? UINavigationController }
        let transitioning = navigations.contains { $0.transitionCoordinator != nil }
        guard transitioning || !pendingEvents.isEmpty || link.timestamp - lastSample > 0.1 else { return }
        lastSample = link.timestamp
        var rows: [[String: Any]] = []
        for n in navigations where n.viewIfLoaded?.window != nil {
            var row: [String: Any] = ["id": id(n), "top": id(n.topViewController),
                "visible": id(n.visibleViewController), "bar": view(n.navigationBar), "prefersLargeTitles": n.navigationBar.prefersLargeTitles,
                "pages": n.viewControllers.map(page)]
            func barViews(_ v: UIView) -> [[String: Any]] {
                [view(v)] + v.subviews.flatMap(barViews)
            }
            row["barViews"] = barViews(n.navigationBar)
            row["backGestures"] = [n.interactivePopGestureRecognizer, n.interactiveContentPopGestureRecognizer].map { gesture in
                ["type": gesture.map { name($0) } ?? "", "enabled": gesture?.isEnabled ?? false,
                 "state": gesture?.state.rawValue ?? -1, "delegate": gesture?.delegate.map { name($0) } ?? ""] as [String: Any]
            }
            if let t = n.transitionCoordinator {
                row["transition"] = ["interactive": t.isInteractive, "percent": t.percentComplete,
                    "cancelled": t.isCancelled, "from": id(t.viewController(forKey: .from)),
                    "to": id(t.viewController(forKey: .to))]
            }
            rows.append(row)
        }
        var scrolls: [[String: Any]] = []
        var fields: [[String: Any]] = []
        var titles: [[String: Any]] = []
        var edges: [[String: Any]] = []
        func views(_ v: UIView) {
            let typeName = name(v).lowercased()
            if typeName.contains("scrolledge") || typeName.contains("backdrop") {
                var row = view(v)
                row["parent"] = v.superview.map { name($0) } ?? ""
                row["maskFrame"] = v.layer.mask.map { rect($0.frame) } ?? []
                row["maskPresentation"] = v.layer.mask?.presentation().map { rect($0.frame) } ?? []
                var chain: [[String: Any]] = []
                var parent = v.superview
                while let ancestor = parent {
                    chain.append(view(ancestor)); parent = ancestor.superview
                }
                row["ancestors"] = chain
                edges.append(row)
            }
            if let s = v as? UIScrollView {
                var row = view(s)
                row["offset"] = [s.contentOffset.x, s.contentOffset.y]
                row["bounds"] = rect(s.bounds)
                row["presentationBounds"] = s.layer.presentation().map { rect($0.bounds) } ?? []
                row["inset"] = insets(s.contentInset)
                row["adjusted"] = insets(s.adjustedContentInset)
                row["keyboardDismiss"] = s.keyboardDismissMode.rawValue
                row["topEdgeHidden"] = s.topEdgeEffect.isHidden
                row["topEdgeStyle"] = String(describing: s.topEdgeEffect.style)

                row["tracking"] = s.isTracking
                row["dragging"] = s.isDragging
                row["owner"] = nativeNavigationPage(containing: s).map { id($0.owner) } ?? ""
                if let table = s as? UITableView, let first = table.indexPathsForVisibleRows?.first {
                    row["firstRow"] = first.row
                    row["firstRowFrame"] = rect(table.convert(table.rectForRow(at: first), to: nil))
                }
                scrolls.append(row)
            }
            if let f = v as? UITextField {
                var row = view(f)
                row["length"] = f.text?.count ?? 0
                row["focused"] = f.isFirstResponder
                fields.append(row)
            }
            if let label = v as? UILabel, label.text == "资料库" {
                var row = view(label)
                row["color"] = String(describing: label.textColor.resolvedColor(with: label.traitCollection))
                row["layerHidden"] = label.layer.isHidden
                row["mask"] = label.layer.mask.map { rect($0.frame) } ?? []
                titles.append(row)
            }
            v.subviews.forEach(views)
        }
        windows.forEach(views)
        let layoutControllers: [[String: Any]] = controllers.compactMap { controller in
            guard let v = controller.viewIfLoaded, v.window != nil else { return nil }
            return ["id": id(controller), "type": name(controller), "parent": id(controller.parent),
                "view": view(v), "additional": insets(controller.additionalSafeAreaInsets),
                "topScroll": id(controller.contentScrollView(for: .top))]
        }
        let state: [String: Any] = ["controllers": layoutControllers, "navigation": rows, "scrolls": scrolls, "fields": fields,
            "titles": titles, "edges": edges, "application": UIApplication.shared.applicationState.rawValue]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return }
        if data != lastState || !pendingEvents.isEmpty {
            write(["event": "sample", "state": state, "events": pendingEvents])
            lastState = data
            pendingEvents.removeAll()
        }
    }

    func touch(_ touch: UITouch) {
        guard let v = touch.view else { return }
        var fields = view(v)
        let p = touch.location(in: nil)
        fields["point"] = [p.x, p.y]
        var ancestors: [[String: Any]] = []
        var parent: UIView? = v
        while let current = parent {
            var row = view(current)
            row["gestures"] = (current.gestureRecognizers ?? []).map { gesture in
                ["type": name(gesture), "state": gesture.state.rawValue, "enabled": gesture.isEnabled,
                 "delegate": gesture.delegate.map { name($0) } ?? ""] as [String: Any]
            }
            ancestors.append(row); parent = current.superview
        }
        fields["ancestors"] = ancestors
        if let page = nativeNavigationPage(containing: v) {
            fields["owner"] = id(page.owner)
            fields["top"] = id(page.navigation.topViewController)
            fields["transitioning"] = page.navigation.transitionCoordinator != nil
        }
        event("touch", fields)
    }

    private func write(_ value: [String: Any]) {
        var entry = value
        entry["time"] = ProcessInfo.processInfo.systemUptime
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              bytes + data.count < 32 * 1024 * 1024 else {
            timer?.invalidate(); timer = nil
            try? output?.close(); output = nil
            return
        }
        data.append(10)
        do { try output?.write(contentsOf: data); bytes += data.count } catch {
            timer?.invalidate(); timer = nil; output = nil
        }
    }
}
@MainActor private final class NativeUITraceTouch: UIGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        touches.forEach { NativeUITrace.shared.touch($0) }
        state = .failed
    }
}
#endif
