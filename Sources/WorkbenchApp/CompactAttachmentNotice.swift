import WorkbenchCore
import SwiftUI

struct CompactAttachmentNotice: View {
    @ObservedObject var draft: TerminalAttachmentDraft
    let close: () -> Void
    @ViewState private var showDetails = false
    var body: some View {
        if draft.inserted {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.teal)
                Text(L10n.text("附件已发送至 \(draft.session.displayName)")).lineLimit(1)
                Spacer()
                Button(L10n.text("详情")) { showDetails.toggle() }
                Button(action: close) { Image(systemName: "xmark") }
            }.font(.system(size: 10)).buttonStyle(.borderless).padding(.horizontal, 12).frame(height: 24).background(.teal.opacity(0.04))
                .popover(isPresented: $showDetails) { TerminalAttachmentBanner(draft: draft, dismiss: close).frame(width: 580) }
        } else { TerminalAttachmentBanner(draft: draft, dismiss: close); Divider() }
    }
}
