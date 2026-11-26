import SwiftUI
import ErosCore

struct ClipboardQuickHint:View {
    let candidates:[GalleryLinkCandidate]
    let ready:Bool
    let open:(GalleryLinkCandidate) -> Void
    let close:() -> Void
    @Environment(\.dynamicTypeSize) private var size
    private var title:String {
        guard let first=candidates.first else{return "剪贴板链接"}
        if candidates.count>1 {return "剪贴板中发现\(candidates.count)个EH/EX链接"}
        return "剪贴板中发现"+(first.target.site == .eh ? "EH" : "EX")+"链接"
    }
    var body:some View {
        Group {
            if size.isAccessibilitySize {
                VStack(alignment:.leading,spacing:6) {Label(title,systemImage:"link");HStack{actions;Spacer(minLength:0)}}
            } else {
                HStack(spacing:12) {Label(title,systemImage:"link").lineLimit(2);Spacer(minLength:4);actions}
            }
        }.font(.subheadline).padding(.horizontal,12).padding(.vertical,6)
            .buttonStyle(.borderless).accessibilityElement(children:.contain)
    }
    @ViewBuilder private var actions:some View {
        if candidates.count==1,let first=candidates.first {
            Button("快速跳转"){open(first)}.disabled(!ready)
        } else {
            Menu("选择跳转") {
                ForEach(candidates) {candidate in
                    Button(candidate.url.absoluteString, systemImage: "link") { open(candidate) }
                }
            }.disabled(!ready)
        }
        Button(action:close) {Image(systemName:"xmark").frame(minWidth:36,minHeight:36)}
            .accessibilityLabel("关闭快速跳转提示")
    }
}
