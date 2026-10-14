import SwiftUI
import WorkbenchCore

struct TransferConflictBanner: View {
    let job: TransferJob
    @ObservedObject var store: AppStore
    @ViewState private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.doc").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(job.name)：目标已存在，是否覆盖？").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text("\(destinationName) · \(job.conflicts?.count ?? 0) 项冲突 · 确认前不覆盖，其他任务继续").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Button(expanded ? "收起" : "查看冲突") { expanded.toggle() }
                Button("取消此任务") { store.cancel(job) }
                Button("覆盖 / 合并并继续") { store.approveOverwrite(job) }.buttonStyle(.borderedProminent)
                    .disabled(job.conflicts?.allSatisfy(\.canReplace) != true)
            }
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("目录只合并；目标中额外的文件保留。类型不兼容、符号链接不会覆盖，请换名称或目标。").foregroundStyle(.secondary)
                        ForEach(Array((job.conflicts ?? []).enumerated()), id: \.offset) { _, conflict in
                            Text("\(conflict.canReplace ? (conflict.incoming.isDirectory ? "合并目录" : "替换文件") : "类型不兼容") · \(conflict.path)").textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 130).font(.caption)
            }
        }.padding(.horizontal, 20).padding(.vertical, 12).background(Color.orange.opacity(0.08))
    }
    private var destinationName: String { job.destination.isLocal ? "此 Mac" : store.hosts.first(where: { $0.id == job.destination.hostID })?.name ?? "未知主机" }
}
