import Foundation
import WorkbenchCore

func checkMonitorProcessSorting() throws {
    var snapshot = try MonitorSnapshot.parse("FARPORT_MONITOR_V1\nprocess\t10\tuser10\t1024\t1\t7200\tworker10\ta\nprocess\t2\tuser2\t2048\t1\t120\tworker2\tb\nprocess\t30\t\t\t1\t\tworker30\tc\nprocess\t4\tuser2\t0\t1\t0\tworker2\td\n", platform: .linux)
    snapshot.processes[0].cpuPercent = 90; snapshot.processes[1].cpuPercent = 9; snapshot.processes[3].cpuPercent = 0
    var sort = MonitorProcessSort()
    try expect(sort.sorted(snapshot.processes).map(\.id) == [10, 2, 4, 30], "进程默认CPU降序且缺失值末尾")
    let expected: [(MonitorProcessColumn, [Int], [Int])] = [(.pid, [2, 4, 10, 30], [30, 10, 4, 2]), (.name, [2, 4, 10, 30], [30, 10, 2, 4]), (.user, [2, 4, 10, 30], [10, 2, 4, 30]), (.cpu, [4, 2, 10, 30], [10, 2, 4, 30]), (.memory, [4, 10, 2, 30], [2, 10, 4, 30]), (.uptime, [4, 2, 10, 30], [10, 2, 4, 30])]
    for (column, ascending, descending) in expected {
        sort.cycle(column)
        try expect(sort.column == column && !sort.descending && sort.sorted(snapshot.processes).map(\.id) == ascending, "进程表\(column)升序按原始值")
        sort.cycle(column)
        try expect(sort.descending && sort.sorted(snapshot.processes).map(\.id) == descending, "进程表\(column)降序且同值PID稳定")
        sort.cycle(column)
        try expect(sort.column == nil && sort.sorted(snapshot.processes).map(\.id) == [10, 2, 4, 30], "进程表第三次点击恢复默认")
    }
    sort.cycle(.cpu); sort.cycle(.cpu); sort.cycle(.memory)
    try expect(sort.column == .memory && !sort.descending, "切换不同列从升序开始")
    let retained = sort
    snapshot.processes[0].cpuPercent = .nan
    let invalidCPU = MonitorProcessComparator(column: .cpu, order: .reverse)
    try expect(snapshot.processes.sorted(using: invalidCPU).map(\.id) == [2, 4, 10, 30], "非有限CPU按缺失值处理")
    snapshot.processes.reverse()
    try expect(sort == retained && sort.sorted(snapshot.processes).map(\.id) == [4, 10, 2, 30], "采集数据顺序变化不改变排序")
    try expect(sort.sorted(snapshot.processes.filter { $0.user == "user2" }).map(\.id) == [4, 2], "筛选使用当前数值排序")
}
