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
            Text(L10n.text("标记颜色 · \(HostMarkColor(storedValue: selection).title)")).font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(HostMarkColor.allCases, id: \.rawValue) { option in
                    Button { selection = option.rawValue } label: {
                        HStack(spacing: 6) {
                            Circle().fill(option.color).frame(width: 16, height: 16)
                                .overlay { if HostMarkColor(storedValue: selection) == option { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.black) } }
                            Text(option.title).font(.system(size: 10, weight: .medium))
                        }.frame(maxWidth: .infinity, minHeight: 32).background(option.color.opacity(HostMarkColor(storedValue: selection) == option ? 0.16 : 0.04), in: RoundedRectangle(cornerRadius: 7))
                            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(option.color.opacity(HostMarkColor(storedValue: selection) == option ? 0.7 : 0.1)) }.contentShape(Rectangle())
                    }.buttonStyle(.plain).help(option.title).accessibilityLabel(option.title)
                        .accessibilityValue(HostMarkColor(storedValue: selection) == option ? L10n.text("已选择") : L10n.text("未选择"))
                }
            }
        }
    }
}
