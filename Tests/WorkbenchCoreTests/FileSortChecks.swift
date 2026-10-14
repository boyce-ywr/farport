import Foundation
import WorkbenchCore

func checkFileSorting() throws {
    let folder = RemoteFile(name: "zzz", path: "/zzz", attributes: FileAttributes(size: 100, permissions: 0o040755, modified: 20))
    let first = RemoteFile(name: "file2.py", path: "/file2.py", attributes: FileAttributes(size: 1000, permissions: 0o100755, modified: 30))
    let second = RemoteFile(name: "file10.pdf", path: "/file10.pdf", attributes: FileAttributes(size: 200, permissions: 0o100600, modified: 10))
    let files = [second, first, folder]
    let defaultOrder = [folder.path, first.path, second.path]
    var sort = FileSort()
    try expect(sort.sorted(files).map(\.path) == defaultOrder, "默认文件夹优先及自然名称排序 2 在 10 前")
    for column in FileSortColumn.allCases {
        sort.cycle(column)
        try expect(sort.column == column && !sort.descending, "首次点击 \(column.title) 为升序")
        let ascending = sort.sorted(files)
        sort.cycle(column)
        try expect(sort.column == column && sort.descending, "第二次点击 \(column.title) 为降序")
        let descending = sort.sorted(files)
        try expect(ascending[0].path == folder.path && descending[0].path == folder.path, "双向排序文件夹仍优先")
        try expect(Array(ascending.dropFirst()).map(\.path) == Array(descending.dropFirst().reversed()).map(\.path), "各列正反序结果相反")
        sort.cycle(column)
        try expect(sort.column == nil && sort.sorted(files).map(\.path) == defaultOrder, "第三次点击恢复默认排序")
    }
    sort.cycle(.size)
    try expect(sort.sorted(files)[1].path == second.path, "大小按真实字节值排序而非显示文本")
    sort.cycle(.modified)
    try expect(sort.sorted(files)[1].path == second.path && !sort.descending, "换列重新升序，时间按时间戳比较")
    sort.cycle(.permissions)
    try expect(sort.sorted(files)[1].path == second.path, "权限忽略文件类型高位")
    try expect(first.typeLabel == "Python 脚本" && second.typeLabel == "PDF 文档" && folder.typeLabel == "文件夹", "常见类型显示中文名称")
    let link = RemoteFile(name: "image.png", path: "/link", attributes: FileAttributes(permissions: 0o120777))
    try expect(link.typeLabel == "符号链接", "链接优先于扩展名")
    let hidden = RemoteFile(name: ".bashrc", path: "/.bashrc", attributes: FileAttributes(permissions: 0o100600))
    try expect(hidden.typeLabel == "文件", "无扩展名隐藏文件类型合理")
    let upper = RemoteFile(name: "INDEX.HTML", path: "/INDEX.HTML", attributes: FileAttributes(permissions: 0o100600))
    try expect(upper.typeLabel == "HTML 网页", "扩展名大小写兼容")
    try expect(FileSort().sorted([]).isEmpty, "空文件列表可排序")
}
