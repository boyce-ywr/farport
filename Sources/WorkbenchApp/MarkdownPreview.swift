import WorkbenchCore
import AppKit
import SwiftUI

@MainActor
enum MarkdownRendering {
    static func render(_ source: String) -> NSAttributedString {
        guard let markdown = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full)) else { return NSAttributedString(string: source) }
        let result = NSMutableAttributedString(string: "")
        var previousBlock: Int?
        var previousTableRow: Int?
        for run in markdown.runs {
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            let row = components.first { component in
                switch component.kind { case .tableRow, .tableHeaderRow: return true; default: return false }
            }?.identity
            let newBlock = block != previousBlock
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 5; paragraph.paragraphSpacing = 10
            var font = NSFont.systemFont(ofSize: 13)
            var prefix = ""
            for component in components {
                switch component.kind {
                case .header(let level): font = NSFont.systemFont(ofSize: CGFloat(max(15, 29 - level * 3)), weight: .bold)
                case .codeBlock:
                    font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular); paragraph.headIndent = 12; paragraph.firstLineHeadIndent = 12
                case .listItem(let ordinal):
                    let ordered = components.contains { if case .orderedList = $0.kind { return true }; return false }
                    prefix = ordered ? "\(ordinal). " : "• "
                    paragraph.headIndent = 20
                case .blockQuote: paragraph.headIndent = 16; paragraph.firstLineHeadIndent = 16; prefix = "▎ "
                default: break
                }
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
            if let inline = run.inlinePresentationIntent {
                if inline.contains(.code) { attributes[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular); attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.12) }
                if inline.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask); attributes[.font] = font }
                if inline.contains(.emphasized) { attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let url = run.link, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { attributes[.link] = url; attributes[.foregroundColor] = NSColor.systemTeal }
            if newBlock {
                if result.length > 0 { result.append(NSAttributedString(string: row != nil && row == previousTableRow ? "\t" : "\n\n")) }
                if !prefix.isEmpty { result.append(NSAttributedString(string: prefix, attributes: attributes)) }
            }
            result.append(NSAttributedString(string: String(markdown[run.range].characters), attributes: attributes))
            previousBlock = block; previousTableRow = row
        }
        return result
    }
}

struct MarkdownPreview: NSViewRepresentable {
    let source: String
    @Environment(\.colorScheme) private var scheme
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false; text.isSelectable = true; text.drawsBackground = false
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 16, height: 16)
        text.delegate = context.coordinator; scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.source != source || context.coordinator.scheme != scheme, let text = scroll.documentView as? NSTextView else { return }
        context.coordinator.source = source; context.coordinator.scheme = scheme
        text.textStorage?.setAttributedString(MarkdownRendering.render(source))
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var source: String?; var scheme: ColorScheme?
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return true }
            if confirm(L10n.text("在浏览器中打开链接？"), url.absoluteString) { NSWorkspace.shared.open(url) }
            return true
        }
    }
}
