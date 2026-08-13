import Foundation
import WebKit

/// Bitwarden autofill, via the official `bw` CLI.
///
/// Security properties, chosen deliberately — a password manager that gets these wrong
/// is worse than no password manager:
///
///  1. **The master password never touches this app.** The user runs `bw unlock`
///     themselves and exports `BW_SESSION`; Kestrel reads it from its own environment
///     and never prompts for, displays, or stores it.
///  2. **The session key is passed to `bw` through the child process environment**, not
///     as an argv element, so it does not appear in `ps` output.
///  3. **Nothing is persisted.** The vault is queried on demand and results are held
///     only for the duration of a fill.
///  4. **Origin must match before filling.** A credential is only offered if the page's
///     registrable domain matches a URI stored on the vault item. This is the check that
///     stops a look-alike page harvesting a saved password.
///  5. **HTTPS only**, and main frame only — no filling into third-party iframes.
///  6. **Fill never submits.** Kestrel populates the fields; the user presses the button.
///  7. **Credentials are never logged**, not even at debug level.
enum Bitwarden {

    struct Credential {
        let name: String
        let username: String
        let password: String
        let uris: [String]
    }

    enum Status: Error {
        case ready
        case cliMissing
        case locked
        case failed(String)

        /// Short form for a menu row.
        var shortLabel: String {
            switch self {
            case .ready: return "unlocked"
            case .cliMissing: return "CLI not installed"
            case .locked: return "locked (export BW_SESSION)"
            case .failed: return "error"
            }
        }

        var message: String {
            switch self {
            case .ready: return "Bitwarden unlocked"
            case .cliMissing:
                return "Bitwarden CLI not found. Install with: brew install bitwarden-cli"
            case .locked:
                return "Vault locked. Run `bw unlock` in a terminal, then relaunch Kestrel "
                     + "with the BW_SESSION it prints exported in the environment."
            case .failed(let m): return "Bitwarden error: \(m)"
            }
        }
    }

    static var cliPath: String? {
        for p in ["/opt/homebrew/bin/bw", "/usr/local/bin/bw", "/usr/bin/bw"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        // Fall back to PATH lookup.
        let which = run("/usr/bin/which", ["bw"], session: nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (which?.isEmpty == false) ? which : nil
    }

    /// Never prompted for, never stored — supplied by the user's own shell.
    static var session: String? {
        let s = ProcessInfo.processInfo.environment["BW_SESSION"]
        return (s?.isEmpty == false) ? s : nil
    }

    static func status() -> Status {
        guard cliPath != nil else { return .cliMissing }
        guard session != nil else { return .locked }
        return .ready
    }

    /// Registrable-domain comparison. Deliberately conservative: `mail.example.com`
    /// matches an item saved for `example.com`, but `example.com.evil.net` does not.
    static func domainMatches(pageHost: String, uri: String) -> Bool {
        guard let uriHost = URL(string: uri)?.host
                ?? URL(string: "https://" + uri)?.host else { return false }
        let a = pageHost.lowercased(), b = uriHost.lowercased()
        if a == b { return true }
        return a.hasSuffix("." + b) || b.hasSuffix("." + a)
    }

    /// Query the vault for credentials whose stored URI matches this page's host.
    static func credentials(forHost host: String) -> Result<[Credential], Status> {
        guard case .ready = status() else { return .failure(status()) }
        guard let cli = cliPath, let session else { return .failure(status()) }

        // The search term narrows the query; the origin check below is what actually
        // gates disclosure.
        guard let out = run(cli, ["list", "items", "--search", host, "--nointeraction"],
                            session: session) else {
            return .failure(.failed("could not run bw"))
        }
        guard let data = out.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            // bw prints human-readable errors on failure; surface a short form only.
            let head = out.split(separator: "\n").first.map(String.init) ?? "unknown"
            return .failure(.failed(String(head.prefix(120))))
        }

        var creds: [Credential] = []
        for item in items {
            guard let login = item["login"] as? [String: Any] else { continue }
            let uriList = (login["uris"] as? [[String: Any]])?
                .compactMap { $0["uri"] as? String } ?? []
            guard uriList.contains(where: { domainMatches(pageHost: host, uri: $0) })
            else { continue }                       // origin gate
            guard let username = login["username"] as? String,
                  let password = login["password"] as? String else { continue }
            creds.append(Credential(name: item["name"] as? String ?? host,
                                    username: username, password: password, uris: uriList))
        }
        return .success(creds)
    }

    /// Fills the credential into the page. Does not submit.
    ///
    /// The JS finds a password field and its associated username field, sets both, and
    /// dispatches the input/change events frameworks listen for. It refuses to run if
    /// the page origin changed between the query and the fill.
    static func fillScript(_ cred: Credential, expectedHost: String) -> String {
        """
        (function () {
          if (location.hostname !== \(jsString(expectedHost))) return 'origin-changed';
          if (location.protocol !== 'https:') return 'not-https';
          const pw = document.querySelector('input[type="password"]:not([disabled])');
          if (!pw) return 'no-password-field';
          const form = pw.form || document;
          const user = form.querySelector(
            'input[type="email"], input[type="text"], input[name*="user" i], ' +
            'input[name*="email" i], input[id*="user" i], input[id*="email" i]');
          const set = (el, v) => {
            if (!el) return;
            const proto = Object.getPrototypeOf(el);
            const d = Object.getOwnPropertyDescriptor(proto, 'value');
            d && d.set ? d.set.call(el, v) : (el.value = v);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          };
          set(user, \(jsString(cred.username)));
          set(pw, \(jsString(cred.password)));
          return 'filled';
        })();
        """
    }

    // MARK: - process plumbing

    private static func run(_ path: String, _ args: [String], session: String?) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        if let session { env["BW_SESSION"] = session }   // env, not argv: stays out of ps
        p.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        if out.isEmpty { return String(data: err, encoding: .utf8) }
        return out
    }

    private static func jsString(_ s: String) -> String {
        // JSON-encode so quotes, backslashes and newlines in a password cannot break out
        // of the string literal or inject code.
        let data = try! JSONSerialization.data(withJSONObject: [s], options: [])
        var text = String(data: data, encoding: .utf8)!
        text.removeFirst(); text.removeLast()          // strip the array brackets
        return text
    }
}
