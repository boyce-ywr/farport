import AppKit
import UniformTypeIdentifiers
import WorkbenchCore

@MainActor
struct FileTransferTarget {
    let model: FileModel
    let store: AppStore
    let isAvailable: () -> Bool

    func snapshot() throws -> FileEndpointSnapshot {
        guard !model.busy, model.path.hasPrefix("/"), isAvailable() else {
            throw WorkbenchError.message(L10n.text("目标目录尚未就绪，未开始复制；请稍后重试。"))
        }
        let snapshot = try FileEndpointSnapshot(endpoints: [FileEndpoint(hostID: model.host?.id, path: model.path)], hosts: model.host.map { [$0] } ?? [])
        try snapshot.validate(hosts: store.hosts)
        return snapshot
    }
    func queue(_ source: FileEndpointSnapshot, to target: FileEndpointSnapshot) throws {
        guard !model.busy, isAvailable(), target.endpoints == [FileEndpoint(hostID: model.host?.id, path: model.path)] else {
            throw WorkbenchError.message(L10n.text("目标目录或分栏已变化，未开始复制，请重新操作。"))
        }
        let count = try store.queueFileReferences(source, to: target)
        model.transferNotice = L10n.text("已加入 \(count) 个复制任务，可在传输队列查看进度。")
    }
    func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        do {
            let target = try snapshot()
            Task {
                do {
                    let references: FileEndpointSnapshot
                    if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.workbenchFiles.identifier) }) {
                        references = try store.draggedFileReferences(await load(provider, type: .workbenchFiles))
                    } else {
                        var endpoints: [FileEndpoint] = []
                        for provider in providers {
                            let data = try await load(provider, type: .fileURL)
                            guard data.count <= 16384, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                                throw WorkbenchError.message(L10n.text("拖入内容不是有效的本地文件。"))
                            }
                            endpoints.append(FileEndpoint(path: url.path))
                        }
                        references = try FileEndpointSnapshot(endpoints: endpoints, hosts: store.hosts)
                    }
                    try queue(references, to: target)
                    if store.draggedFiles?.id == references.id { store.draggedFiles = nil }
                } catch { model.errorMessage = error.localizedDescription }
            }
            return true
        } catch { model.errorMessage = error.localizedDescription; return false }
    }
    private func load(_ provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? WorkbenchError.message(L10n.text("无法读取拖拽文件信息。"))) }
            }
        }
    }
}
