import AppKit
import SwiftUI
import WorkbenchCore

struct SourcePreview: NSViewRepresentable {
    let source: String
    let language: SyntaxLanguage
    @Environment(\.colorScheme) private var scheme
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.drawsBackground = false
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false; text.isSelectable = true; text.drawsBackground = false
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true; text.textContainerInset = NSSize(width: 14, height: 12)
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticLinkDetectionEnabled = false
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.source != source || context.coordinator.scheme != scheme || context.coordinator.language != language,
              let text = scroll.documentView as? NSTextView else { return }
        context.coordinator.source = source; context.coordinator.scheme = scheme; context.coordinator.language = language
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        let attributed = NSMutableAttributedString(string: source, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        for token in SyntaxHighlighting.tokens(source, language: language) {
            let color: NSColor
            switch token.kind {
            case .key: color = .systemTeal
            case .string: color = .systemGreen
            case .number: color = .systemOrange
            case .literal: color = .systemPurple
            case .tag: color = .systemBlue
            case .comment: color = .secondaryLabelColor
            case .keyword: color = .systemPurple
            case .function: color = .systemTeal
            case .variable: color = .systemPink
            }
            attributed.addAttribute(.foregroundColor, value: color, range: token.range)
        }
        text.textStorage?.setAttributedString(attributed)
    }
    final class Coordinator {
        var source: String?; var scheme: ColorScheme?; var language: SyntaxLanguage?
    }
}
