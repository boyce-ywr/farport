import AppKit
import SwiftUI
import WorkbenchCore

@MainActor
enum CompactLayoutChecks {
    static func run(store: AppStore, output: URL) async throws {
        let root = store.paths.root.appendingPathComponent("finder-fixture")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("报告 中文.txt")
        try Data("Farport Finder check".utf8).write(to: target)
        var download = TransferJob(source: FileEndpoint(hostID: UUID(), path: "/reports/report.txt"), destination: FileEndpoint(path: target.path))
        download.status = .completed; download.totalBytes = 27100000; download.completedBytes = download.totalBytes
        var upload = download; upload.id = UUID(); upload.source = FileEndpoint(path: target.path); upload.destination = FileEndpoint(hostID: UUID(), path: "/reports/report.txt")
        var remote = download; remote.id = UUID(); remote.destination.hostID = UUID()
        guard TransferFileLocation.url(for: download)?.path == target.path, TransferFileLocation.url(for: upload)?.path == target.path,
              TransferFileLocation.url(for: remote) == nil else { throw WorkbenchError.message("Finder 定位源/目标选择错误") }
        for state in [TransferStatus.running, .failed, .cancelled, .paused, .queued] {
            var unfinished = download; unfinished.status = state
            guard TransferFileLocation.url(for: unfinished) == nil else { throw WorkbenchError.message("未完成任务错误暴露 Finder 入口") }
        }
        try TransferFileLocation.reveal(download)
        let snapshot = try MonitorSnapshot.parse("""
        FARPORT_MONITOR_V1
        disk\t/\t245110000000\t14000000000\t72000000000
        disk\t/System/Volumes/Data\t245110000000\t157000000000\t72000000000
        disk\t/Volumes/Projects\t1000000000000\t480000000000\t520000000000
        disk\t/Volumes/Backup\t2000000000000\t800000000000\t1200000000000
        """, platform: .macOS)
        let info = ["os": "macOS", "kernel": "Darwin", "architecture": "arm64", "hostname": "dev-machine", "model": "Mac mini", "cpuModel": "Apple M4", "logicalCPUs": "10", "physicalCPUs": "10", "username": "developer", "uid": "501", "home": "/Users/developer", "shell": "/bin/zsh", "groups": "staff everyone localaccounts admin developers com.apple.access_ssh com.apple.access_screensharing"]
        for width in [CGFloat(720), 1100] {
            let row = NSHostingView(rootView: TransferRow(job: download, store: store).frame(width: width))
            guard row.fittingSize.height <= 64 else { throw WorkbenchError.message("已完成传输行过高：\(row.fittingSize.height)") }
            let disks = NSHostingView(rootView: MonitorDiskList(disks: snapshot.disks).frame(width: width))
            guard disks.fittingSize.height <= 164 else { throw WorkbenchError.message("四项磁盘列表过高：\(disks.fittingSize.height)") }
            let system = NSHostingView(rootView: MonitorSystemDetails(info: info).frame(width: width))
            guard system.fittingSize.height <= 440 else { throw WorkbenchError.message("系统信息过高：\(system.fittingSize.height)") }
            print("PASS · 宽度 \(width)：传输行 \(row.fittingSize.height)，四行磁盘 \(disks.fittingSize.height)，完整系统信息 \(system.fittingSize.height)")
        }
        let originalTransfers = store.transfers
        defer { store.transfers = originalTransfers }
        var running = upload; running.id = UUID(); running.status = .running; running.completedBytes = 11000000; running.message = L10n.text("传输中")
        var failed = upload; failed.id = UUID(); failed.status = .failed; failed.message = L10n.text("连接已中断")
        store.transfers = [download, upload, running, failed]
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            try await capture(TransferWorkspace(store: store), width: 1000, height: 540, scheme: scheme, output: output.deletingLastPathComponent().appendingPathComponent("transfers-\(suffix).png"))
            try await capture(VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("磁盘与挂载点")).font(.headline)
                MonitorDiskList(disks: snapshot.disks)
                MonitorSystemDetails(info: info)
            }.padding(20), width: 900, height: 640, scheme: scheme, output: output.deletingLastPathComponent().appendingPathComponent("monitor-\(suffix).png"))
        }
        try FileManager.default.removeItem(at: target)
        do { try TransferFileLocation.reveal(download); throw WorkbenchError.message("丢失文件没有报错") }
        catch WorkbenchError.message(let message) { guard message == L10n.text("本机文件已移动或删除，无法在 Finder 中定位。") else { throw WorkbenchError.message(message) } }
        print("PASS · Finder 本机目标/上传源路径、远端互传隐藏入口、丢失文件提示、紧凑布局与深浅截图")
    }
    private static func capture<Content: View>(_ view: Content, width: CGFloat, height: CGFloat, scheme: ColorScheme, output: URL) async throws {
        let hosting = NSHostingView(rootView: view.frame(width: width, height: height, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme).environment(\.locale, L10n.language.locale).tint(.teal))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting; window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(250)); hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw WorkbenchError.message("无法生成布局截图") }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output)
    }
}
