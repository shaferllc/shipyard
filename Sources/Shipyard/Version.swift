/// A VERSION the shared release can tag: exactly three numbers, x.y.z.
/// Anything else ("1.0", "v1.2.3", "1.2.3-beta") is left for a person to fix
/// rather than guessed at — a wrong guess cuts a tag nothing else matches.
struct Version: Equatable, CustomStringConvertible, Sendable {
    enum Part: String, CaseIterable, Sendable { case patch, minor, major }

    var major: Int
    var minor: Int
    var patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(_ string: String) {
        let parts = string.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2])
        else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    func bumped(_ part: Part) -> Version {
        switch part {
        case .patch: Version(major: major, minor: minor, patch: patch + 1)
        case .minor: Version(major: major, minor: minor + 1, patch: 0)
        case .major: Version(major: major + 1, minor: 0, patch: 0)
        }
    }

    var description: String { "\(major).\(minor).\(patch)" }
}
