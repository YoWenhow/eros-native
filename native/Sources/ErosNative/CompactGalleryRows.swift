import SwiftUI
import ErosCore
import ErosServices

/// Compact covers have a stable footprint while text may grow at accessibility sizes.
struct CompactGalleryRow: View {
    let summary: GallerySummary
    let previews: PreviewImageLoader
    let scope: SessionScope
    let downloadStatus: GalleryDownloadStatus?
    let detailSource: DetailTransitionSource
    var body: some View {
        GalleryTitleView(summary: summary, scope: scope) { title in
            label(title: title)
        }
    }

    func label(title: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            GalleryCoverSource(source: detailSource) {
                CompactGalleryCover(summary: summary, previews: previews, scope: scope)
            }.frame(width: 108, height: 144)
            CompactGalleryInfo(summary: summary, title: title, downloadStatus: downloadStatus)
        }.accessibilityElement(children: .combine).contentShape(Rectangle())
    }
}

/// Separate native controls keep cover navigation independent from continuing a history entry.
struct CompactHistoryRow: View {
    let entry: HistoryEntry
    let previews: PreviewImageLoader
    let scope: SessionScope
    let downloadStatus: GalleryDownloadStatus?
    let detailSource: DetailTransitionSource
    let openCover: () -> Void
    let openReader: () -> Void
    @ObservedObject private var preferences = PreferencesStore.shared
    var body: some View {
        let title = entry.summary.displayTitle(preferred: preferences.value.galleryTitleStyle)
        HStack(alignment: .top, spacing: 10) {
            Button(action: openCover) {
                GalleryCoverSource(source: detailSource) {
                    CompactGalleryCover(summary: entry.summary, previews: previews, scope: scope)
                }.frame(width: 108, height: 144)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("打开画廊详情：" + title)
            Button(action: openReader) {
                CompactGalleryInfo(summary: entry.summary, title: title, downloadStatus: downloadStatus)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("继续阅读：" + title)
                .galleryDownloadAccessibility(downloadStatus)
        }
    }
}

private struct CompactGalleryCover: View {
    let summary: GallerySummary
    let previews: PreviewImageLoader
    let scope: SessionScope
    var body: some View {
        OnlinePreview(url: summary.coverURL, loader: previews, scope: scope)
            .frame(width: 108, height: 144).clipped().accessibilityHidden(true).id(scope)
    }
}

private struct CompactGalleryInfo: View {
    let summary: GallerySummary
    let title: String
    let downloadStatus: GalleryDownloadStatus?
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        let metadata = languageAndPages
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim:title).font(.subheadline)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            CompactListTags(groups: summary.listTags ?? [])
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    if let category = summary.category { GalleryCategoryBadge(category: category) }
                    if let rating = summary.rating { GalleryStars(rating: rating) }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    if downloadStatus != nil || !metadata.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            if let downloadStatus {
                                Group {
                                    if downloadStatus.isComplete {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    } else {
                                        Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
                                    }
                                }.accessibilityHidden(true)
                            }
                            if !metadata.isEmpty { Text(metadata) }
                        }.font(.caption2)
                    }
                    if let uploadTime { Text(uploadTime).font(.caption2).monospacedDigit() }
                }.foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        }.frame(minHeight: 144, alignment: .topLeading)
            .frame(height: typeSize.isAccessibilitySize ? nil : 144, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var languageAndPages: String {
        let names = ["japanese":"日语", "english":"英语", "chinese":"汉语", "korean":"韩语", "french":"法语", "german":"德语", "spanish":"西班牙语", "russian":"俄语", "italian":"意大利语", "portuguese":"葡萄牙语", "thai":"泰语", "vietnamese":"越南语", "polish":"波兰语"]
        let languages = (summary.listTags ?? []).flatMap { group in
            group.tags.filter { group.namespace == "language" || (group.namespace == nil && names[$0] != nil) }
        }.filter { !["translated", "rewrite", "speechless"].contains($0) }
        let language = languages.first.map { names[$0] ?? $0 }
        return [language, summary.pageCount.map { "\($0.value) 页" }].compactMap { $0 }.joined(separator: " · ")
    }
    private var uploadTime: String? {
        guard let date = summary.postedAt else { return nil }
        return Self.dateFormatter.string(from: date)
    }
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"; return formatter
    }()
}

struct CompactDownloadRow: View {
    let item: DownloadLibraryItem
    let coordinator: DownloadCoordinator
    let scope: SessionScope
    var selecting = false
    let galleryDetailSource: DetailTransitionSource
    var openCover: () -> Void
    var openReader: () -> Void
    var controlBusy:Bool
    var control:()->Void
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        GalleryTitleView(summary: item.summary, scope: scope) { title in
            row(title: title)
        }
    }

    private func row(title: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: openCover) {
                GalleryCoverSource(source: galleryDetailSource) {
                    LocalDownloadCover(item: item, coordinator: coordinator, scope: scope)
                }.frame(width: 108, height: 150).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(!selecting)
            .accessibilityHidden(selecting)
            .accessibilityLabel("打开画廊详情：" + title)
            Button(action: openReader) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).font(.subheadline)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                Text((item.sourceKind == .pages ? "逐页" : "归档") + " · " + ByteCountFormatter.string(fromByteCount:Int64(item.storedBytes.value),countStyle:.file))
                    .font(.caption2).foregroundStyle(.secondary)
                Group {
                    if !item.metadata.artists.isEmpty { TranslatedDownloadValues(title: "作者", namespace: "artist", values: item.metadata.artists, state: item.metadata.state) }
                    if !item.metadata.groups.isEmpty { TranslatedDownloadValues(title: "社团", namespace: "group", values: item.metadata.groups, state: item.metadata.state) }
                }.font(.caption2).foregroundStyle(.secondary).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: 6) {
                    VStack(alignment: .leading, spacing: 4) {
                        if item.sourceKind == .archive {
                            Text("归档").font(.caption2).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.orange, in: RoundedRectangle(cornerRadius: 4))
                        } else if item.variant == .original {
                            Text("原图").font(.caption2).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.red, in: RoundedRectangle(cornerRadius: 4))
                        }
                        if let rating = item.summary.rating { GalleryStars(rating: rating) }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(status).font(.caption).foregroundStyle(item.state == .failed ? .red : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if item.sourceKind == .archive && item.state == .failed {
                            Text("点击查看失败原因").font(.caption2).foregroundStyle(.orange)
                        }
                        if item.state == .downloading {
                            TimelineView(.periodic(from:.now,by:0.5)) { _ in
                                let speed=TransferProgress.shared.snapshot(owner:.download(StorageScope(accountID:scope.storage.accountID,site:item.summary.reference.key.site),item.jobID)).bytesPerSecond
                                Text(ByteCountFormatter.string(fromByteCount:Int64(speed),countStyle:.file)+"/s").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        if item.addedAt != nil {
                            Text(DownloadMetadataPresentation.timestamp(item.addedAt)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }.multilineTextAlignment(.trailing)
                }
                if item.sourceKind == .archive && item.state == .downloading {
                    ArchiveByteProgressBar(owner:.download(StorageScope(accountID:scope.storage.accountID,
                        site:item.summary.reference.key.site),item.jobID))
                } else if item.sourceKind == .archive && item.state == .completed {
                    HStack(spacing:6) {
                        ProgressView(value:1,total:1).progressViewStyle(.linear).tint(.green)
                        Text("100%").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    }.accessibilityElement(children:.ignore)
                        .accessibilityLabel("归档文件下载完成")
                        .accessibilityValue("100%")
                } else if item.state != .completed && item.sourceKind == .pages {
                    ProgressView(value: Double(item.state == .completed && item.progressTotal == 0 ? 1 : item.completedPages.value), total: Double(max(1, item.progressTotal)))
                }
            }.frame(minHeight: 150, alignment: .topLeading).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(!selecting)
            .accessibilityHidden(selecting)
            .accessibilityLabel((item.sourceKind == .archive && item.state == .failed ? "查看归档失败原因：" : "继续离线阅读：") + (item.sourceKind == .archive ? "归档，" : (item.variant == .original ? "原图，" : "")) + title)
            if !selecting {
                VStack {
                    Spacer(minLength:0)
                    Group {
                        if item.state == .completed {
                            Image(systemName:item.sourceKind == .archive ? "archivebox.fill" : "checkmark.circle.fill")
                                .font(.title2).foregroundStyle(.green)
                                .frame(width:44,height:44)
                                .accessibilityLabel(item.sourceKind == .archive ? "归档下载完成" : "下载完成")
                        } else {
                            Button(action:control) {
                                Group {
                                    if controlBusy { ProgressView() }
                                    else { Image(systemName:DownloadStateMachine.restartable(item.state) ? "pause.fill" : "play.fill") }
                                }.frame(width:44,height:44)
                            }.buttonStyle(.plain).foregroundStyle(.tint)
                                .accessibleGlass(in:Circle()).disabled(controlBusy)
                                .accessibilityLabel(DownloadStateMachine.restartable(item.state) ? "暂停下载" : "继续下载")
                        }
                    }.contentShape(Rectangle()).onTapGesture { }
                    Spacer(minLength:0)
                }.frame(width:44,height:150)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: selecting ? .ignore : .contain)
        .accessibilityLabel(Text(verbatim: title), isEnabled: selecting)
    }
    private var status: String {
        let label = downloadStateLabel(item.state)
        return "\(label) · \(item.completedPages.value)/\(item.progressTotal) 页" + (item.skippedPages.value > 0 ? " · 屏蔽\(item.skippedPages.value)" : "")
    }
}

private struct ArchiveByteProgressBar: View {
    let owner: TransferOwner
    var body: some View {
        TimelineView(.periodic(from:.now,by:0.5)) { _ in
            let value=TransferProgress.shared.snapshot(owner:owner)
            VStack(alignment:.leading,spacing:3) {
                if let expected=value.expected {
                    Text(ByteCountFormatter.string(fromByteCount:value.received,countStyle:.file)
                         + " / " + (value.isEstimated ? "约" : "")
                         + ByteCountFormatter.string(fromByteCount:expected,countStyle:.file))
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                } else if value.received>0 {
                    Text("已下载 " + ByteCountFormatter.string(fromByteCount:value.received,countStyle:.file))
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
                HStack(spacing:6) {
                    if let fraction=value.fraction {
                        ProgressView(value:fraction,total:1).progressViewStyle(.linear)
                        Text("\(Int(fraction*100))%")
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
            }.accessibilityElement(children:.combine)
                .accessibilityLabel("归档文件下载进度")
        }
    }
}
