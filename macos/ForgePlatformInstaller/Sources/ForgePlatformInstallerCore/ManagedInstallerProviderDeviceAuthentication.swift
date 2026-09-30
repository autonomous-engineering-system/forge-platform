import Foundation

/// A fixed provider-owned device ceremony. No request supplies an executable,
/// argument, URL, environment key, home or account. The helper derives those
/// from the admitted exact target and executes under its component account.
struct ManagedInstallerProviderDeviceAuthenticationCommand: Equatable, Sendable {
    let provider: ProviderID
    let arguments: [String]
    let environment: [String: String]

    init?(requirement: ProviderRequirement, componentHome: URL) {
        guard requirement.credentialScope == .component,
              requirement.runtime != nil,
              componentHome.isFileURL, componentHome.baseURL == nil,
              componentHome.path.hasPrefix("/") else { return nil }
        provider = requirement.provider
        var values = [
            "HOME": componentHome.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C", "LC_ALL": "C", "NO_COLOR": "1", "TERM": "dumb",
        ]
        switch requirement.provider {
        case .codex:
            arguments = ["login", "--device-auth"]
            values["CODEX_HOME"] = componentHome.path
        case .githubCLI:
            arguments = [
                "auth", "login", "--web", "--hostname", "github.com",
                "--git-protocol", "https", "--skip-ssh-key",
            ]
            values["GH_CONFIG_DIR"] = componentHome.path
            values["GH_NO_UPDATE_NOTIFIER"] = "1"
            // The operator opens the fixed device URL from the installer UI;
            // a root-owned daemon may not open a user's browser session.
            values["BROWSER"] = "/usr/bin/true"
        }
        environment = values
    }
}

/// Ephemeral UI-only prompt from the provider CLI. It is never journaled or
/// included in a terminal provider receipt. The activation URL is fixed by
/// provider identity; arbitrary CLI output cannot choose a link.
struct ManagedInstallerProviderDeviceChallenge: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible {
    let provider: ProviderID
    let verificationURL: URL
    let userCode: String

    var description: String { "<provider device challenge: redacted>" }
    var debugDescription: String { description }

    static func parse(provider: ProviderID, output: Data) -> Self? {
        guard !output.isEmpty, output.count <= 4 * 1_024,
              let raw = String(data: output, encoding: .utf8) else { return nil }
        let prompt: String
        let url: String
        switch provider {
        case .codex:
            prompt = "Enter this one-time code"
            url = "https://auth.openai.com/codex/device"
        case .githubCLI:
            prompt = "First copy your one-time code"
            url = "https://github.com/login/device"
        }
        // Only SGR coloring from the provider's own terminal output is
        // tolerated. Other terminal escapes and control bytes fail closed.
        let sgr = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*m")
        let plain = sgr.stringByReplacingMatches(
            in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: ""
        )
        guard !plain.unicodeScalars.contains(where: {
            ($0.value < 32 && $0 != "\n" && $0 != "\r" && $0 != "\t")
                || $0.value == 127
        }),
              plain.contains(url),
              let marker = plain.range(of: prompt),
              plain.range(of: prompt, range: marker.upperBound..<plain.endIndex) == nil,
              let pattern = try? NSRegularExpression(
                  pattern: "\\b[A-Z0-9]{4}-[A-Z0-9]{4}\\b"
              ) else { return nil }
        let suffix = String(plain[marker.upperBound...].prefix(160))
        let matches = pattern.matches(
            in: suffix, range: NSRange(suffix.startIndex..., in: suffix)
        )
        guard matches.count == 1,
              let range = Range(matches[0].range, in: suffix),
              let verificationURL = URL(string: url) else { return nil }
        return Self(provider: provider, verificationURL: verificationURL,
                    userCode: String(suffix[range]))
    }
}
