import SwiftUI
import ErosCore

enum ReaderRoute: Hashable {
    case online(GalleryReference, PageIndex?, SessionScope)
    case download(UUID, PageIndex?, SessionScope)

    var scope: SessionScope {
        switch self {
        case .online(_, _, let scope), .download(_, _, let scope): scope
        }
    }
}

struct ReaderPresentation: Identifiable {
    let id = UUID()
    let route: ReaderRoute
}

private struct OpenReaderKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable (ReaderRoute) -> Void = { _ in }
}

extension EnvironmentValues {
    var openReader: @MainActor @Sendable (ReaderRoute) -> Void {
        get { self[OpenReaderKey.self] }
        set { self[OpenReaderKey.self] = newValue }
    }
}

struct ReaderPresentationView: View {
    let route: ReaderRoute
    @ObservedObject var model: OnlineLibraryModel
    let context: LinkBrowseContext?

    @ViewBuilder var body: some View {
        switch route {
        case let .online(reference, index, scope):
            if model.canRequestNetwork, (context?.scope ?? model.state?.scope) == scope,
               let services = context?.services ?? model.services,
               let pipeline = context?.pipeline ?? model.readerPipeline {
                let previews = context?.previews ?? model.previews
                if let index {
                    OnlineReaderView(services: services, pipeline: pipeline, previews: previews, reference: reference,
                        index: index, scope: scope, downloads: context == nil ? model.downloads : nil)
                } else {
                    OnlineResumeView(services: services, pipeline: pipeline, previews: previews, reference: reference, scope: scope)
                }
            } else {
                unavailable
            }
        case let .download(id, index, scope):
            if model.canOpenLocalLibrary, model.state?.scope == scope,
               let services = model.services, let coordinator = model.downloads {
                DownloadResumeView(id: id, coordinator: coordinator, database: services.database,
                    sessions: services.sessions, scope: scope, requestedIndex: index)
            } else {
                unavailable
            }
        }
    }

    private var unavailable: some View {
        ReaderPresentationStatus {
            NativeStateView(title: "暂时无法阅读", message: "请关闭阅读页并检查当前会话。", symbol: "book.closed")
        }
    }
}

struct ReaderCancelButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .accessibleGlass(in: Circle())
        .accessibilityLabel("取消阅读")
    }
}

struct ReaderPresentationStatus<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .overlay(alignment: .topLeading) {
                ReaderCancelButton { dismiss() }.padding(.leading, 16).padding(.top, 6)
            }
            .accessibilityAction(.escape) { dismiss() }
    }
}
