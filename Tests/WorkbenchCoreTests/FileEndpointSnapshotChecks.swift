import Foundation
import WorkbenchCore

func checkFileEndpointSnapshots() throws {
    let host = HostProfile(name: "fixture", address: "fixture.invalid")
    let endpoint = FileEndpoint(hostID: host.id, path: "/folder/file.txt")
    let snapshot = try FileEndpointSnapshot(endpoints: [endpoint], hosts: [host])
    try snapshot.validate(hosts: [host])
    try expect(snapshot.endpoints == [endpoint], "文件引用保留真实主机和路径")
    var renamed = host; renamed.name = "new label"
    try snapshot.validate(hosts: [renamed])
    try expect(snapshot.endpoints[0].hostID == renamed.id, "仅改显示名称不改变复制目标")
    var changed = host; changed.address = "different.invalid"
    try rejects("主机变更后拒绝旧文件复制") { try snapshot.validate(hosts: [changed]) }
    try rejects("主机移除后拒绝旧文件复制") { try snapshot.validate(hosts: []) }
    try rejects("不存在的主机不能捕获引用") { _ = try FileEndpointSnapshot(endpoints: [endpoint], hosts: []) }
    try rejects("空文件复制不覆盖剪贴板") { _ = try FileEndpointSnapshot(endpoints: [], hosts: []) }
    try rejects("相对路径不能成为复制目标") { _ = try FileEndpointSnapshot(endpoints: [FileEndpoint(path: "relative")], hosts: []) }
    try rejects("空字符路径不能复制") { _ = try FileEndpointSnapshot(endpoints: [FileEndpoint(path: "/bad\0")], hosts: []) }
    let local = try FileEndpointSnapshot(endpoints: [FileEndpoint(path: "/")], hosts: [])
    try local.validate(hosts: [])
    try expect(local.endpoints[0].hostID == nil, "本机目标不依赖远端主机")
}
