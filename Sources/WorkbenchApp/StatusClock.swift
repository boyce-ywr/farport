import SwiftUI
import WorkbenchCore

struct StatusClock: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(Self.display(context.date))
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 36)
                .help(L10n.text("本机时间"))
                .accessibilityLabel(L10n.text("本机时间"))
                .accessibilityValue(Self.display(context.date))
        }
    }
    static func display(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
