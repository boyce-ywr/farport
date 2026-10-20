import SwiftUI
import WorkbenchCore
import OpenSSHBackend

struct ContainerAttachmentPicker: View {
    @ObservedObject var draft: TerminalAttachmentDraft
    let selection: DockerAttachmentSelection
    @ViewState private var selectedID: String?
    private var user: String {
        let value = selection.terminal.invocation.user ?? selection.containers.first(where: { $0.id == selection.detectedContainerID })?.user ?? ""
        return value.isEmpty ? "root" : value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("选择目标容器")).font(.headline)
            Text(L10n.text("Docker context：\(selection.daemon.context) · 原窗格：\(selection.terminal.target.paneID)"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("只允许选择已核对为原窗格目标的容器。按该 docker exec 用户或容器配置用户复制，不提权、不自动回车。"))
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            List(selection.containers, selection: $selectedID) { container in
                HStack {
                    Image(systemName: container.id == selection.detectedContainerID ? "checkmark.shield" : "shippingbox")
                    VStack(alignment: .leading) {
                        Text(container.displayName)
                        Text(String(container.id.prefix(12))).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if container.id == selection.detectedContainerID { Text(L10n.text("原窗格容器")).font(.caption).foregroundStyle(.teal) }
                }.tag(container.id)
            }.frame(height: 190)
            Text(L10n.text("容器接收用户：\(user)")).font(.caption).textSelection(.enabled)
            Text(L10n.text("确认当前输入程序就在此容器中；若容器内又进入 SSH、其他容器或切换用户，请取消。"))
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            if let failure = draft.failure { Text(failure).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(L10n.text("取消")) { draft.cancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                if draft.preparing { ProgressView().controlSize(.small) }
                Button(L10n.text("确认容器并复制附件")) {
                    if let selectedID { Task { await draft.chooseContainer(selectedID) } }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(selectedID != selection.detectedContainerID || draft.preparing)
            }
        }.padding(20).frame(width: 480)
            .onAppear { selectedID = selection.detectedContainerID }
    }
}
