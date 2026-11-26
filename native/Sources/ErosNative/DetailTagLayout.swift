import SwiftUI

enum DetailTagSpacing {
    static let tag: CGFloat = 4
    static let namespace = 3 * tag
}

/// Shrink-wrap the badge while retaining the existing scaled width cap and narrow-row wrapping.
struct DetailTagNamespaceLayout: Layout {
    let maximumWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let badge = subviews.first else { return .zero }
        let natural = badge.sizeThatFits(.unspecified)
        let width = max(1, min(maximumWidth, proposal.width ?? natural.width, natural.width))
        return badge.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// Full wrapping for detail tags (no three-row truncation used by list cards).
struct TagWrappingLayout: Layout {
    private func boxes(_ width: CGFloat, _ views: Subviews) -> ([CGRect], CGFloat) {
        var result: [CGRect] = []; var x: CGFloat = 0; var y: CGFloat = 0; var height: CGFloat = 0
        for view in views {
            let natural = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(ProposedViewSize(width:min(width,natural.width),height:nil))
            if x > 0 && x + size.width > width { y += height + DetailTagSpacing.tag; x = 0; height = 0 }
            result.append(CGRect(x:x,y:y,width:min(width,size.width),height:size.height))
            x += size.width + DetailTagSpacing.tag; height = max(height,size.height)
        }
        return (result,result.isEmpty ? 0 : y+height)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(1,proposal.width ?? 240)
        return CGSize(width:width,height:boxes(width,subviews).1)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i,rect) in boxes(max(1,bounds.width),subviews).0.enumerated() {
            subviews[i].place(at:CGPoint(x:bounds.minX+rect.minX,y:bounds.minY+rect.minY),anchor:.topLeading,proposal:ProposedViewSize(width:rect.width,height:rect.height))
        }
    }
}

enum TagNamespaceColor {
    // Original Flutter ThemeColors.tagColorTagType, light and dark RGB.
    private static let palette: [String:(UInt32,UInt32)] = [
        "artist":(0xE6D6D0,0x5E544E), "female":(0xFAE0D4,0x906F44), "male":(0xF9EED8,0x968A4A),
        "parody":(0xD8E6E2,0x487068), "character":(0xD5E4F7,0x49677F), "group":(0xDFD6F7,0x615284),
        "language":(0xF5D5E5,0x7F4A6B), "reclass":(0xFBD6D5,0x925554), "misc":(0xD7D7D6,0x63666A),
        "temp":(0xD7D7D6,0x63666A), "other":(0xFBD6D5,0x925554), "cosplayer":(0xF5D5E5,0x7F4A6B)
    ]
    static func color(_ namespace:String?) -> Color {
        let pair = palette[namespace ?? "misc"] ?? palette["misc"]!
        return Color(uiColor:UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? pair.1 : pair.0
            return UIColor(red:CGFloat((rgb >> 16)&255)/255,green:CGFloat((rgb >> 8)&255)/255,blue:CGFloat(rgb&255)/255,alpha:1)
        })
    }
    static var tagBackground: Color { Color(uiColor:UIColor { $0.userInterfaceStyle == .dark ? .secondaryLabel : UIColor(white:238.0/255,alpha:1) }) }
    static var tagText: Color { Color(uiColor:UIColor { $0.userInterfaceStyle == .dark ? .systemGray4 : UIColor(white:80.0/255,alpha:1) }) }
}
