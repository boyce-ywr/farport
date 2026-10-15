import AppKit
import SwiftUI
import WorkbenchCore

@MainActor
enum StatusClockChecks {
    static func run() throws {
        for (seconds, offset, expected) in [(0.0, 0, "00:00"), (45000, 28800, "20:30"), (86340, 0, "23:59"), (86400, 0, "00:00"), (0, 20700, "05:45")] {
            guard StatusClock.display(Date(timeIntervalSince1970: seconds), timeZone: TimeZone(secondsFromGMT: offset)!) == expected else { throw WorkbenchError.message("状态栏时间格式或跨日错误") }
        }
        let clock = NSHostingView(rootView: StatusClock().font(.system(size: 10)))
        guard clock.fittingSize.width == 36, clock.fittingSize.height <= 22 else { throw WorkbenchError.message("状态栏时钟占位大小错误") }
        print("PASS · 状态栏时钟：24 小时制、前导零、跨日、时区、固定宽度不撑高")
    }
}
