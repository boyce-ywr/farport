import AppKit
import AVKit
import CoreVideo
import Foundation
import WorkbenchCore
import OpenSSHBackend

@MainActor
enum FileNavigationMediaChecks {
    static func run(workspace: Workspace, scene: String) async throws {
        let transport = workspace.store.transport
        guard let host = workspace.store.hosts.first, host.address == "127.0.0.1", [22281, 22282].contains(host.port) else { throw WorkbenchError.message("仅允许隔离 SSH 主机") }
        let local = workspace.store.paths.root.appendingPathComponent("media-fixture")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let remote = "/tmp/farport-preview-" + UUID().uuidString
        try await Task.detached {
            try makeVideo(local.appendingPathComponent("demo.mp4"))
            try makeAudio(local.appendingPathComponent("demo.wav"))
            try Data("{\n  \"project\": \"Farport\",\n  \"description\": \"中文内容保留 · Hello\",\n  \"version\": 7,\n  \"enabled\": true,\n  \"items\": [1, 2, 3],\n  \"optional\": null\n}\n".utf8).write(to: local.appendingPathComponent("settings.json"))
            try Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!-- Read-only source preview -->\n<project name=\"Farport\">\n  <description>中文内容保留 · Hello</description>\n  <feature enabled=\"true\">SSH</feature>\n  <feature enabled=\"true\">SFTP</feature>\n</project>\n".utf8).write(to: local.appendingPathComponent("settings.xml"))
            try Data("package demo;\n\n// Remote Java source preview\npublic class Hello {\n    private static final int PORT = 22;\n\n    public static void main(String[] args) {\n        String greeting = \"你好，Farport 😀\";\n        System.out.println(greeting);\n        boolean connected = true;\n    }\n}\n".utf8).write(to: local.appendingPathComponent("Hello.java"))
            try Data("from pathlib import Path\n\n# Remote Python source preview\ndef greet(name: str) -> str:\n    \"\"\"生成欢迎消息。\"\"\"\n    message = f\"你好，{name} 😀\"\n    return message\n\nif __name__ == \"__main__\":\n    retries = 3\n    enabled = True\n    print(greet(\"Farport\"))\n".utf8).write(to: local.appendingPathComponent("hello.py"))
            let client = try transport.files(host); defer { client.close() }
            try client.mkdir(remote); try client.mkdir(remote + "/first"); try client.mkdir(remote + "/other")
            for name in ["demo.mp4", "demo.wav", "settings.json", "settings.xml", "Hello.java", "hello.py"] {
                let data = try Data(contentsOf: local.appendingPathComponent(name))
                let file = remote + "/" + name; try client.createFile(file)
                try client.saveText(file, data: data, expected: client.stat(file), original: Data())
            }
        }.value
        workspace.browseFiles(.host(host.id))
        guard let model = workspace.currentFileBrowser else { throw WorkbenchError.message("没有文件来源") }
        try await wait { !model.busy }
        model.load(remote + "/first"); try await wait { !model.busy && model.path == remote + "/first" }
        model.load(remote + "/other"); try await wait { !model.busy && model.path == remote + "/other" }
        let beforeRefresh = model.history
        model.load(); try await wait { !model.busy }
        guard model.history == beforeRefresh else { throw WorkbenchError.message("刷新污染浏览历史") }
        model.goBack(); try await wait { !model.busy && model.path == remote + "/first" }
        guard model.path != RemotePath.parent(remote + "/other") else { throw WorkbenchError.message("返回错误地变成了上一级") }
        let beforeFailure = model.history
        model.load(remote + "/does-not-exist"); try await wait { !model.busy }
        guard model.history == beforeFailure, model.errorMessage != nil else { throw WorkbenchError.message("失败导航改变历史") }
        model.load(remote + "/cancelled"); model.load(remote)
        try await wait { !model.busy && model.path == remote }
        guard !model.history.previous.contains(remote + "/cancelled"), model.errorMessage == nil else { throw WorkbenchError.message("取消导航污染历史或错误提示") }
        let remoteHistory = model.history
        workspace.browseFiles(.local); workspace.browseFiles(.host(host.id))
        guard workspace.currentFileBrowser === model, model.history == remoteHistory else { throw WorkbenchError.message("来源切换丢失历史") }
        if scene == "media-preview" {
            for name in ["demo.wav", "demo.mp4"] {
                guard let file = model.files.first(where: { $0.name == name }) else { throw WorkbenchError.message("缺少媒体文件") }
                model.selection = [file.path]; model.preview(file)
                try await wait { !model.previewBusy && model.mediaURL != nil }
                try await wait { player(in: NSApp.windows.first(where: { $0.isVisible })?.contentView) != nil }
                let player = player(in: NSApp.windows.first(where: { $0.isVisible })?.contentView)!
                try await wait { player.currentItem?.status == .readyToPlay }
                guard player.rate == 0 else { throw WorkbenchError.message("媒体自动播放") }
                let videoOutput = name == "demo.mp4" ? AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]) : nil
                if let videoOutput { player.currentItem?.add(videoOutput) }
                player.isMuted = true; player.play()
                try await wait { player.currentTime().seconds > 0.2 }
                if let videoOutput {
                    try await wait { videoOutput.hasNewPixelBuffer(forItemTime: player.currentTime()) }
                    guard let pixel = videoOutput.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil), CVPixelBufferGetWidth(pixel) == 640 else { throw WorkbenchError.message("视频未输出真实解码帧") }
                    CVPixelBufferLockBaseAddress(pixel, .readOnly)
                    let first = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
                    let colored = first[0] > 10 || first[1] > 10 || first[2] > 10
                    CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
                    guard colored else { throw WorkbenchError.message("视频解码帧意外全黑") }
                }
                player.pause()
                await player.seek(to: CMTime(seconds: 1.5, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                try await wait { abs(player.currentTime().seconds - 1.5) < 0.3 }
                print("PASS · \(name) 远端 AVPlayer 加载、播放、暂停与 seek")
            }
            let url = model.mediaURL!
            model.stopMediaPreview()
            let revoked = try await Task.detached { try ProcessRunner.run(executable: "/usr/bin/curl", arguments: ["--noproxy", "*", "--max-time", "3", "-fsS", url.absoluteString], timeout: 5) }.value
            guard revoked.status != 0 else { throw WorkbenchError.message("媒体服务停止后仍可读取") }
            model.startMediaPreview(); try await wait { !model.previewBusy && model.mediaURL != nil }
            try await wait { player(in: NSApp.windows.first(where: { $0.isVisible })?.contentView)?.currentItem?.status == .readyToPlay }
        } else {
            let filename = ["xml-preview": "settings.xml", "java-preview": "Hello.java", "python-preview": "hello.py"][scene] ?? "settings.json"
            guard let file = model.files.first(where: { $0.name == filename }) else { throw WorkbenchError.message("缺少高亮示例文件") }
            model.selection = [file.path]; model.preview(file); try await wait { !model.previewBusy && !model.previewData.isEmpty }
            try await Task.sleep(for: .milliseconds(300))
            guard let text = sourceText(in: NSApp.windows.first(where: { $0.isVisible })?.contentView), text.string == model.previewText else { throw WorkbenchError.message("高亮未保留源文件内容") }
            var colors = Set<String>()
            text.textStorage?.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.string.utf16.count)) { value, _, _ in colors.insert(String(describing: value)) }
            guard colors.count >= 3 else { throw WorkbenchError.message("未渲染高亮颜色") }
        }
        model.previewRatio = 0.52
        if L10n.language == .english {
            guard WorkspacePage.files.title == "Files", FileSortColumn.name.title == "Name", L10n.text("返回上次访问的目录") == "Back to the previous folder" else { throw WorkbenchError.message("英文核心界面未生效") }
        }
        print("PASS · 目录返回/刷新/失败/取消/来源隔离，\(scene)，界面语言 \(L10n.language.rawValue)")
    }
    static func player(in view: NSView?) -> AVPlayer? {
        guard let view else { return nil }
        if let media = view as? AVPlayerView { return media.player }
        for child in view.subviews { if let player = player(in: child) { return player } }
        return nil
    }
    private static func sourceText(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let text = view as? NSTextView, text.textStorage?.length ?? 0 > 50 { return text }
        for child in view.subviews { if let text = sourceText(in: child) { return text } }
        return nil
    }
    nonisolated private static func makeAudio(_ url: URL) throws {
        let rate = 16000; let samples = rate * 3
        var data = Data("RIFF".utf8)
        func append<Value: FixedWidthInteger>(_ value: Value) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        append(UInt32(36 + samples * 2)); data.append(Data("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16)); data.append(Data("data".utf8)); append(UInt32(samples * 2))
        for index in 0..<samples { append(Int16(sin(Double(index) / Double(rate) * 440 * 2 * .pi) * 3000)) }
        try data.write(to: url)
    }
    nonisolated private static func makeVideo(_ url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360])
        writer.add(input); guard writer.startWriting() else { throw writer.error ?? WorkbenchError.message("视频生成失败") }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<60 {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData { guard Date() < deadline, writer.status == .writing else { throw WorkbenchError.message("视频编码超时") }; Thread.sleep(forTimeInterval: 0.01) }
            var pixel: CVPixelBuffer?
            guard let pool = adapter.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else { throw WorkbenchError.message("无法创建视频帧") }
            CVPixelBufferLockBaseAddress(pixel, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            context.setFillColor(CGColor(red: 0.04, green: 0.15, blue: 0.2, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
            context.setFillColor(CGColor(red: 0.05, green: 0.72, blue: 0.76, alpha: 1)); context.fill(CGRect(x: 30 + index * 5, y: 100, width: 160, height: 160))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adapter.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 20)) else { throw writer.error ?? WorkbenchError.message("视频帧写入失败") }
        }
        input.markAsFinished(); let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        guard done.wait(timeout: .now() + 20) == .success, writer.status == .completed else { throw writer.error ?? WorkbenchError.message("视频编码未完成") }
    }
    private static func wait(line: Int = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() { guard Date() < deadline else { throw WorkbenchError.message("预览验证超时：\(line)") }; try await Task.sleep(for: .milliseconds(100)) }
    }
}
