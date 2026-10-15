import Foundation
import Observation

public enum AppLanguage: String, CaseIterable, Sendable {
    case system, simplifiedChinese = "zh-Hans", english = "en"
    public static func resolve(_ choice: String, preferred: [String]) -> AppLanguage {
        if let language = AppLanguage(rawValue: choice), language != .system { return language }
        return preferred.first?.hasPrefix("zh") == true ? .simplifiedChinese : .english
    }
    public var locale: Locale { Locale(identifier: self == .simplifiedChinese ? "zh_Hans" : "en_US") }
}

public struct LocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    public let key: String
    public let arguments: [String]
    public init(stringLiteral value: String) { key = value; arguments = [] }
    public init(stringInterpolation: StringInterpolation) { key = stringInterpolation.key; arguments = stringInterpolation.arguments }
    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""; var arguments: [String] = []
        public init(literalCapacity: Int, interpolationCount: Int) { key.reserveCapacity(literalCapacity); arguments.reserveCapacity(interpolationCount) }
        public mutating func appendLiteral(_ literal: String) { key += literal }
        public mutating func appendInterpolation<Value>(_ value: Value) { key += "{\(arguments.count)}"; arguments.append(String(describing: value)) }
    }
}

private final class RuntimeLanguage: Observable, @unchecked Sendable {
    private let registrar = ObservationRegistrar()
    private let lock = NSLock()
    private var stored: AppLanguage
    init(_ language: AppLanguage) { stored = language }
    var value: AppLanguage {
        get { registrar.access(self, keyPath: \.value); return lock.withLock { stored } }
        set { registrar.withMutation(of: self, keyPath: \.value) { lock.withLock { stored = newValue } } }
    }
}

public enum L10n {
    public static let preferenceDefaults: UserDefaults = ProcessInfo.processInfo.environment["SWB_HOME"] == nil
        ? .standard : UserDefaults(suiteName: "local.sshworkbench.qa.language")!
    private static let runtime: RuntimeLanguage = {
        let environment = ProcessInfo.processInfo.environment
        let choice = environment["FARPORT_LANGUAGE"] ?? (environment["SWB_HOME"] == nil ? preferenceDefaults.string(forKey: "farport.language") ?? "system" : "zh-Hans")
        return RuntimeLanguage(AppLanguage.resolve(choice, preferred: Locale.preferredLanguages))
    }()
    public static var language: AppLanguage { runtime.value }
    public static func setPreference(_ choice: String) {
        let resolved = AppLanguage.resolve(choice, preferred: Locale.preferredLanguages)
        if runtime.value != resolved { runtime.value = resolved }
    }
    public static let translations: [String: String] = {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let packaged = [Bundle.main.resourceURL?.appendingPathComponent("SSHWorkbench_WorkbenchCore.bundle"),
                        executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/SSHWorkbench_WorkbenchCore.bundle")]
        let bundle = packaged.compactMap { $0.flatMap { Bundle(url: $0) } }.first ?? Bundle.module
        guard let url = bundle.url(forResource: "en", withExtension: "json"), let data = try? Data(contentsOf: url),
              let translations = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return translations
    }()
    public static func text(_ message: LocalizedMessage) -> String { render(message, language: language) }
    public static func key(_ source: String) -> String { language == .english ? translations[source] ?? source : source }
    public static func render(_ message: LocalizedMessage, language: AppLanguage) -> String {
        let template = language == .english ? translations[message.key] ?? message.key : message.key
        guard !message.arguments.isEmpty else { return template }
        var output = ""; var cursor = template.startIndex
        while cursor < template.endIndex {
            if template[cursor] == "{", let end = template[cursor...].firstIndex(of: "}"),
               let index = Int(template[template.index(after: cursor)..<end]), message.arguments.indices.contains(index) {
                output += message.arguments[index]; cursor = template.index(after: end)
            } else { output.append(template[cursor]); cursor = template.index(after: cursor) }
        }
        return output
    }
}
