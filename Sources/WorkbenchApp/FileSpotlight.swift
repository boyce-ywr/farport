import SwiftUI
import AppKit
import WorkbenchCore

enum PreviewFamily: Equatable {
    case image, media, pdf, text, other
    static func of(_ file: RemoteFile) -> PreviewFamily {
        if file.attributes.isDirectory { return .other }
        let ext = (file.name as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "tiff", "webp", "heic"].contains(ext) { return .image }
        if ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "mp4", "m4v", "mov", "webm", "mkv", "ogg", "opus"].contains(ext) { return .media }
        if ext == "pdf" { return .pdf }
        if ["zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso", "so", "dylib", "class", "jar", "bin"].contains(ext) { return .other }
        return .text
    }
    var title: LocalizedMessage {
        switch self {
        case .image: return "图片"
        case .media: return "音视频"
        case .pdf: return "PDF"
        case .text: return "文本"
        case .other: return "其他"
        }
    }
}

struct FilePreviewContentView: View {
    @ObservedObject var model: FileModel
    @Binding var showHTMLSource: Bool
    @Binding var showMarkdownSource: Bool
    var imageScale: CGFloat = 1
    var body: some View {
        Group {
            if let file = model.previewFile {
                if file.attributes.isDirectory || model.previewTargetIsDirectory {
                    VStack(spacing: 15) {
                        Image(systemName: file.attributes.isSymbolicLink ? "folder.badge.questionmark" : "folder.fill").font(.system(size: 58)).foregroundStyle(.teal.opacity(0.7))
                        if file.attributes.isSymbolicLink { Text(L10n.text("符号链接指向文件夹")).font(.caption).foregroundStyle(.secondary) }
                        Button(file.attributes.isSymbolicLink ? L10n.text("打开链接目标文件夹") : L10n.text("打开文件夹")) { model.activate(file) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.isMedia {
                    if let url = model.mediaURL { MediaPreview(url: url).id(url) }
                    else { VStack { Text(model.previewBusy ? L10n.text("正在准备音视频…") : L10n.text("音视频预览已停止")); Button(L10n.text("重新预览")) { model.startMediaPreview() } }.font(.caption).frame(maxWidth: .infinity, maxHeight: .infinity) }
                } else if model.isMarkdown && !showMarkdownSource && !model.binaryPreview {
                    HStack {
                        Text(L10n.text("Markdown 预览")).foregroundStyle(.secondary)
                        Spacer(); Button(L10n.text("查看源码")) { showMarkdownSource = true }
                    }.font(.caption).padding(10)
                    MarkdownPreview(source: model.previewText)
                    if file.attributes.size > UInt64(model.previewData.count) { Text(L10n.text("当前仅预览前 512 KiB；查看源码可翻页。")).font(.caption).foregroundStyle(.secondary).padding(10) }
                } else if let document = model.previewPDF {
                    PDFDocumentPreview(document: document)
                } else if model.isHTML && !showHTMLSource {
                    HStack {
                        Button(L10n.text("源码")) { showHTMLSource = true }
                        if let url = model.webURL { Button(L10n.text("在浏览器打开")) { NSWorkspace.shared.open(url) } }
                        Spacer()
                        Button(model.webScripts ? L10n.text("禁用脚本") : L10n.text("允许脚本…")) {
                            if model.webScripts { model.startWebPreview() }
                            else if confirm(L10n.text("信任此 HTML 报告的脚本？"), L10n.text("脚本将能读取报告所在目录及子目录中的文件。外部网络请求仍被阻止。仅对你信任的报告启用。")) { model.startWebPreview(allowScripts: true) }
                        }
                    }.font(.caption).buttonStyle(.borderless).padding(10)
                    if let url = model.webURL { HTMLPreview(url: url, allowsScripts: model.webScripts).id(url) }
                    else { VStack { Text(model.previewBusy ? L10n.text("正在启动安全预览…") : L10n.text("网页预览已停止")); Button(L10n.text("重新预览")) { model.startWebPreview() } }.font(.caption).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    HStack {
                        Text(L10n.text("仅本机可访问 · 范围：当前 HTML 所在目录")).lineLimit(1).help(L10n.text("相对资源按需通过 SFTP 读取；路径不能越出目录，符号链接和外部网络被阻止。关闭应用后链接失效。"))
                        Spacer(); Button(L10n.text("停止服务")) { model.stopWebPreview() }
                    }.font(.system(size: 10)).foregroundStyle(.secondary).padding(10)
                } else if let image = model.previewImage {
                    GeometryReader { viewport in
                        ScrollView([.horizontal, .vertical]) {
                            Image(nsImage: image).resizable().scaledToFit().scaleEffect(imageScale).padding(16)
                                .frame(minWidth: viewport.size.width, minHeight: viewport.size.height)
                        }
                    }
                } else if model.binaryPreview {
                    VStack(alignment: .leading, spacing: 12) { Label(L10n.text("二进制文件"), systemImage: "doc.zipper"); Text(L10n.text("可下载或传输到另一台主机。不会把二进制内容作为文本写回。")).font(.caption).foregroundStyle(.secondary); Text(model.previewData.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }.padding(18)
                    Spacer()
                } else {
                    if model.isHTML { Button(L10n.text("网页预览")) { showHTMLSource = false }.font(.caption).padding(10) }
                    if model.isMarkdown { Button(L10n.text("Markdown 预览")) { showMarkdownSource = false }.font(.caption).padding(10) }
                    if let syntax = SyntaxHighlighting.language(for: file.path) { SourcePreview(source: model.previewText, language: syntax) }
                    else { ScrollView([.horizontal, .vertical]) { Text(model.previewText).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineSpacing(5).frame(maxWidth: .infinity, alignment: .topLeading).padding(16) } }
                    Divider()
                    HStack {
                        Button { model.followLog = false; model.preview(file, offset: model.previewOffset > UInt64(model.previewLimit) ? model.previewOffset - UInt64(model.previewLimit) : 0) } label: { Image(systemName: "chevron.left") }.disabled(model.previewOffset == 0)
                        Text("\(bytes(model.previewOffset)) / \(bytes(file.attributes.size))").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        Button { model.followLog = false; model.preview(file, offset: model.previewOffset + UInt64(model.previewData.count)) } label: { Image(systemName: "chevron.right") }.disabled(model.previewOffset + UInt64(model.previewData.count) >= file.attributes.size)
                        Spacer()
                        Toggle(L10n.text("跟随"), isOn: $model.followLog).toggleStyle(.checkbox).font(.system(size: 10)).help(L10n.text("每两秒读取文件末尾，适用于日志"))
                    }.buttonStyle(.borderless).padding(12)
                }
            }
        }
    }
}

struct FileSpotlightOverlay: View {
    @ObservedObject var model: FileModel
    let file: RemoteFile
    @ViewState private var expanded = false
    @ViewState private var showHTMLSource = false
    @ViewState private var showMarkdownSource = false
    @ViewState private var imageScale: CGFloat = 1
    @ViewState private var scaleBase: CGFloat = 1
    @ViewState private var hoveringPrevious = false
    @ViewState private var hoveringNext = false
    private var siblings: [RemoteFile] { model.spotlightSiblings(for: file) }
    private var index: Int { siblings.firstIndex(where: { $0.path == file.path }) ?? 0 }
    private var hasPrevious: Bool { index > 0 }
    private var hasNext: Bool { index < siblings.count - 1 }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Rectangle().fill(.black.opacity(0.38))
                }.ignoresSafeArea()
                    .onTapGesture { model.closeSpotlight() }
                card(width: cardWidth(in: geometry.size), height: cardHeight(in: geometry.size))
                    .overlay(alignment: .leading) {
                        if hasPrevious { arrow(left: true, hovering: hoveringPrevious) { model.stepSpotlight(-1) }.onHover { hoveringPrevious = $0 }.offset(x: expanded ? 14 : -54) }
                    }
                    .overlay(alignment: .trailing) {
                        if hasNext { arrow(left: false, hovering: hoveringNext) { model.stepSpotlight(1) }.onHover { hoveringNext = $0 }.offset(x: expanded ? -14 : 54) }
                    }
            }
        }
        .background(Group {
            Button { model.stepSpotlight(-1) } label: { EmptyView() }.keyboardShortcut(.leftArrow, modifiers: []).disabled(!hasPrevious)
            Button { model.stepSpotlight(1) } label: { EmptyView() }.keyboardShortcut(.rightArrow, modifiers: []).disabled(!hasNext)
            Button { model.closeSpotlight() } label: { EmptyView() }.keyboardShortcut(.cancelAction)
        })
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: expanded)
        .animation(.easeOut(duration: 0.16), value: file.path)
        .onChange(of: file.path) { _, _ in imageScale = 1; scaleBase = 1 }
    }
    private func cardWidth(in size: CGSize) -> CGFloat { expanded ? max(360, size.width - 48) : min(1000, max(480, size.width - 180)) }
    private func cardHeight(in size: CGSize) -> CGFloat { expanded ? max(300, size.height - 48) : min(720, max(380, size.height - 120)) }
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: fileIcon(file)).foregroundStyle(Color.teal).font(.system(size: 15))
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(file.typeLabel)
                    Text("·")
                    Text(bytes(file.attributes.size))
                    if siblings.count > 1 {
                        Text("·")
                        Text(L10n.text("\(index + 1)/\(siblings.count)"))
                        Text(L10n.text(PreviewFamily.of(file).title))
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if siblings.count > 1 { Text(L10n.text("← → 切换同类型文件")).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1) }
            Button { expanded.toggle() } label: { Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                .help(expanded ? L10n.text("还原预览窗口") : L10n.text("放大预览窗口"))
            Button { model.closeSpotlight() } label: { Image(systemName: "xmark") }.help(L10n.text("关闭预览（Esc）"))
        }.buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 12)
    }
    private func card(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            header
            Divider()
            FilePreviewContentView(model: model, showHTMLSource: $showHTMLSource, showMarkdownSource: $showMarkdownSource, imageScale: imageScale)
                .gesture(MagnifyGesture()
                    .onChanged { value in imageScale = min(6, max(0.25, scaleBase * value.magnification)) }
                    .onEnded { _ in scaleBase = imageScale })
                .simultaneousGesture(TapGesture(count: 2).onEnded { imageScale = 1; scaleBase = 1 })
        }
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.42), radius: 30, x: 0, y: 18)
    }
    private func arrow(left: Bool, hovering: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: left ? "chevron.left" : "chevron.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white.opacity(hovering ? 0.95 : 0.6))
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.black.opacity(hovering ? 0.5 : 0.3)))
                .overlay(Circle().strokeBorder(Color.white.opacity(hovering ? 0.28 : 0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .help(left ? L10n.text("上一个同类型文件（←）") : L10n.text("下一个同类型文件（→）"))
    }
}
