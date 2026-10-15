import Foundation

public struct ReleaseVersion: Comparable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 else { return nil }
        var numbers: [Int] = []
        for component in components {
            guard !component.isEmpty, component.utf8.allSatisfy({ (48...57).contains($0) }),
                  component.count == 1 || component.first != "0", let number = Int(component) else { return nil }
            numbers.append(number)
        }
        major = numbers[0]; minor = numbers[1]; patch = numbers[2]
    }
    public var description: String { "\(major).\(minor).\(patch)" }
    public static func < (left: Self, right: Self) -> Bool {
        (left.major, left.minor, left.patch) < (right.major, right.minor, right.patch)
    }
}

public struct GitHubReleaseAsset: Decodable, Sendable {
    public let id: Int64
    public let name: String
    public let size: Int64
    public let digest: String?
    public var sha256: String? {
        guard let digest, digest.hasPrefix("sha256:") else { return nil }
        let value = String(digest.dropFirst(7)).lowercased()
        guard value.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return value
    }
}

public struct GitHubRelease: Decodable, Sendable {
    public let id: Int64
    public let tag_name: String
    public let name: String?
    public let body: String?
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [GitHubReleaseAsset]
}

public struct ReleaseUpdate: Sendable {
    public let release: GitHubRelease
    public let version: ReleaseVersion
    public let asset: GitHubReleaseAsset?

    public static func select(from releases: [GitHubRelease], current: String, architecture: String) throws -> ReleaseUpdate? {
        guard let currentVersion = ReleaseVersion(current) else { throw WorkbenchError.message(L10n.text("当前应用版本格式无法识别，未执行自动版本比较。")) }
        let candidates = releases.compactMap { release -> (GitHubRelease, ReleaseVersion)? in
            guard !release.draft, !release.prerelease, release.id > 0, let version = ReleaseVersion(release.tag_name), version > currentVersion else { return nil }
            return (release, version)
        }
        guard let selected = candidates.max(by: { $0.1 < $1.1 }) else { return nil }
        let names = ["Farport-\(selected.1.description)-\(architecture).dmg", "Farport-\(selected.1.description)-universal.dmg"]
        let asset = names.compactMap { expected in
            selected.0.assets.first { $0.name == expected && $0.id > 0 && $0.size > 0 && $0.size <= 1024 * 1024 * 1024 && $0.sha256 != nil }
        }.first
        return ReleaseUpdate(release: selected.0, version: selected.1, asset: asset)
    }
}
