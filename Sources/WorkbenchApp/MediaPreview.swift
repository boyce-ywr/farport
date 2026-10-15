import WorkbenchCore
import AppKit
import AVKit
import SwiftUI

struct MediaPreview: View {
    let url: URL
    @ViewState private var failure: String?
    var body: some View {
        VStack(spacing: 10) {
            MediaPlayerSurface(url: url, failure: $failure)
            if let failure {
                Text(L10n.text("无法播放：\(failure)")).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            Text(L10n.text("按需读取音视频，不自动播放。编码支持取决于 macOS；无法播放时可下载后用其他播放器打开。"))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(10)
    }
}

struct MediaPlayerSurface: NSViewRepresentable {
    let url: URL
    @Binding var failure: String?
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(); view.controlsStyle = .inline; view.videoGravity = .resizeAspect
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.stop(); context.coordinator.url = url
        let item = AVPlayerItem(url: url); let player = AVPlayer(playerItem: item)
        context.coordinator.player = player; view.player = player
        context.coordinator.observation = item.observe(\.status, options: [.initial, .new]) { item, _ in
            if item.status == .failed { DispatchQueue.main.async { failure = item.error?.localizedDescription ?? L10n.text("不支持此媒体编码或网络已断开。") } }
        }
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) { coordinator.stop(); view.player = nil }
    final class Coordinator {
        var url: URL?; var player: AVPlayer?; var observation: NSKeyValueObservation?
        func stop() { observation = nil; player?.pause(); player?.replaceCurrentItem(with: nil); player = nil }
    }
}
