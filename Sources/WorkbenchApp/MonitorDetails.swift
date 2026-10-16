import SwiftUI
import WorkbenchCore

struct MonitorDiskList: View {
    let disks: [MonitorDisk]
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(L10n.text("挂载点")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L10n.text("已用 / 总量")).frame(width: 155, alignment: .trailing)
                Text(L10n.text("可用空间")).frame(width: 85, alignment: .trailing)
                Text(L10n.text("使用率")).frame(width: 130, alignment: .trailing)
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ForEach(Array(disks.enumerated()), id: \.element.id) { index, disk in
                HStack(spacing: 12) {
                    Text(disk.mount).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        .help(disk.mount).frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(size(disk.usedBytes)) / \(size(disk.totalBytes))").frame(width: 155, alignment: .trailing)
                    Text(size(disk.availableBytes)).foregroundStyle(.secondary).frame(width: 85, alignment: .trailing)
                    HStack(spacing: 8) {
                        ProgressView(value: min(1, disk.usedBytes / disk.totalBytes)).controlSize(.small).tint(.teal).frame(width: 78)
                        Text(String(format: "%.0f%%", disk.usedBytes / disk.totalBytes * 100)).monospacedDigit().frame(width: 36, alignment: .trailing)
                    }.frame(width: 130, alignment: .trailing)
                }.font(.system(size: 11)).padding(.horizontal, 12).frame(height: 32)
                    .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.025) : Color.clear)
            }
        }.background(.quaternary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary.opacity(0.5)))
    }
    private func size(_ value: Double) -> String { bytes(UInt64(max(0, min(value, Double(UInt64.max / 2))))) }
}

struct MonitorSystemDetails: View {
    let info: [String: String]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                section("操作系统", symbol: "desktopcomputer", fields: [("os", "操作系统"), ("kernel", "内核版本"), ("architecture", "架构"), ("hostname", "主机名")])
                section("硬件", symbol: "cpu", fields: [("model", "硬件型号"), ("cpuModel", "CPU 型号"), ("logicalCPUs", "逻辑核心"), ("physicalCPUs", "物理核心")])
            }
            section("当前登录用户", symbol: "person.crop.circle", fields: [("username", "当前登录用户"), ("uid", "用户标识"), ("home", "主目录"), ("shell", "Shell / 采集环境"), ("groups", "用户组")])
        }
    }
    private func section(_ title: String, symbol: String, fields: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(L10n.key(title), systemImage: symbol).font(.system(size: 12, weight: .semibold)).padding(.bottom, 9)
            ForEach(fields, id: \.0) { field in
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(L10n.key(field.1)).foregroundStyle(.secondary).frame(width: 104, alignment: .leading)
                    Text(info[field.0].flatMap { $0.isEmpty ? nil : $0 } ?? "—").textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(size: 12)).padding(.vertical, 6)
            }
        }.padding(12).background(.quaternary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary.opacity(0.5)))
    }
}
