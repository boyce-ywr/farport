import AppKit
import UniformTypeIdentifiers
import WorkbenchCore

extension UTType {
    static let workbenchFiles = UTType(exportedAs: "local.sshworkbench.file-references", conformingTo: .data)
}

extension AppStore {
    static let filePasteboardType = NSPasteboard.PasteboardType(UTType.workbenchFiles.identifier)
    var fileClipboard: [FileEndpoint] {
        guard let copiedFiles, NSPasteboard.general.changeCount == copiedFilesChangeCount,
              NSPasteboard.general.string(forType: Self.filePasteboardType) == copiedFiles.id.uuidString else { return [] }
        return copiedFiles.endpoints
    }
    func copyFileReferences(_ endpoints: [FileEndpoint], sourceHost: HostProfile? = nil) throws {
        let snapshot = try FileEndpointSnapshot(endpoints: endpoints, hosts: sourceHost.map { [$0] } ?? hosts)
        try snapshot.validate(hosts: hosts)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(snapshot.id.uuidString, forType: Self.filePasteboardType),
              pasteboard.string(forType: Self.filePasteboardType) == snapshot.id.uuidString else {
            throw WorkbenchError.message(L10n.text("文件复制信息写入剪贴板失败，请重试。"))
        }
        copiedFiles = snapshot; copiedFilesChangeCount = pasteboard.changeCount
    }
    func pastedFileReferences() throws -> FileEndpointSnapshot {
        let pasteboard = NSPasteboard.general
        if pasteboard.availableType(from: [Self.filePasteboardType]) != nil {
            guard let copiedFiles, !fileClipboard.isEmpty else {
                throw WorkbenchError.message(L10n.text("文件复制信息已失效，请重新选择并复制。"))
            }
            try copiedFiles.validate(hosts: hosts); return copiedFiles
        }
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else {
            throw WorkbenchError.message(L10n.text("剪贴板没有可粘贴的文件，请先在文件列表中按 ⌘C。"))
        }
        return try FileEndpointSnapshot(endpoints: urls.map { FileEndpoint(path: $0.path) }, hosts: hosts)
    }
    func fileDragProvider(_ endpoints: [FileEndpoint], sourceHost: HostProfile? = nil) throws -> NSItemProvider {
        let candidate = try FileEndpointSnapshot(endpoints: endpoints, hosts: sourceHost.map { [$0] } ?? hosts)
        try candidate.validate(hosts: hosts)
        let snapshot: FileEndpointSnapshot
        if let current = draggedFiles, current.endpoints == candidate.endpoints, (try? current.validate(hosts: hosts)) != nil { snapshot = current }
        else { snapshot = candidate }
        draggedFiles = snapshot
        let data = Data(snapshot.id.uuidString.utf8)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.workbenchFiles.identifier, visibility: .ownProcess) { completion in
            completion(data, nil); return nil
        }
        return provider
    }
    func draggedFileReferences(_ data: Data) throws -> FileEndpointSnapshot {
        guard data.count <= 64, let identifier = String(data: data, encoding: .utf8),
              let draggedFiles, draggedFiles.id.uuidString == identifier else {
            throw WorkbenchError.message(L10n.text("文件拖拽信息已失效，请重新拖拽。"))
        }
        try draggedFiles.validate(hosts: hosts); return draggedFiles
    }
    @discardableResult
    func queueFileReferences(_ source: FileEndpointSnapshot, to destination: FileEndpointSnapshot) throws -> Int {
        try source.validate(hosts: hosts); try destination.validate(hosts: hosts)
        guard destination.endpoints.count == 1 else { throw WorkbenchError.message(L10n.text("请选择一个目标目录。")) }
        let count = transfers.count
        try queueFiles(source.endpoints, to: destination.endpoints[0])
        return transfers.count - count
    }
}
