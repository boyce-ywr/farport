import SwiftUI
import WorkbenchCore

extension HostMarkColor {
    var color: Color {
        switch self {
        case .mint: return .teal
        case .blue: return .blue
        case .green: return .green
        case .orange: return .orange
        case .yellow: return .yellow
        case .red: return .red
        case .pink: return .pink
        case .purple: return .purple
        case .indigo: return .indigo
        case .gray: return .gray
        }
    }
}

extension HostProfile {
    var markColor: Color { HostMarkColor(storedValue: color).color }
}

struct HostColorPicker: View {
    @Binding var selection: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("标记颜色 · \(HostMarkColor(storedValue: selection).title)").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                ForEach(HostMarkColor.allCases, id: \.rawValue) { option in
                    Button { selection = option.rawValue } label: {
                        Circle().fill(option.color).frame(width: 23, height: 23)
                            .overlay { if HostMarkColor(storedValue: selection) == option { Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(.black) } }
                            .frame(width: 31, height: 34).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(option.title).accessibilityLabel(option.title)
                        .accessibilityValue(HostMarkColor(storedValue: selection) == option ? "已选择" : "未选择")
                }
            }
        }
    }
}
