import Foundation

public enum TransferBatch {
    public static func jobs(sources: [FileEndpoint], destinationDirectory: FileEndpoint, overwrite: Bool = false) throws -> [TransferJob] {
        guard !sources.isEmpty else { throw WorkbenchError.message("请先选择文件或文件夹。") }
        guard destinationDirectory.path.hasPrefix("/"), !destinationDirectory.path.contains("\0") else { throw WorkbenchError.message("目标必须是有效的绝对目录路径。") }
        var unique: [FileEndpoint] = []
        for original in sources {
            guard original.path.hasPrefix("/"), !original.path.contains("\0") else { throw WorkbenchError.message("源路径必须是有效的绝对路径。") }
            let endpoint = FileEndpoint(hostID: original.hostID, path: (original.path as NSString).standardizingPath)
            if !unique.contains(endpoint) { unique.append(endpoint) }
        }
        unique = unique.filter { candidate in !unique.contains { other in other != candidate && other.hostID == candidate.hostID && candidate.path.hasPrefix(other.path + "/") } }
        let folder = (destinationDirectory.path as NSString).standardizingPath
        var names: Set<String> = []
        return try unique.map { source in
            let name = (source.path as NSString).lastPathComponent
            guard source.path != "/", RemotePath.validName(name) else { throw WorkbenchError.message("不能复制根目录或无效文件名。") }
            guard names.insert(name).inserted else { throw WorkbenchError.message("所选源中存在同名条目“\(name)”，请分批选择目标。") }
            let destination = FileEndpoint(hostID: destinationDirectory.hostID, path: RemotePath.join(folder, name))
            guard source.hostID != destination.hostID || (destination.path != source.path && !destination.path.hasPrefix(source.path + "/")) else {
                throw WorkbenchError.message("不能复制到原位置或自身子目录：\(name)")
            }
            return TransferJob(source: source, destination: destination, overwrite: overwrite)
        }
    }
}
