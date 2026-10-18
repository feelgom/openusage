import Foundation

/// A sibling Claude Code config folder (`~/.claude-<name>`) with a signed-in account.
struct ClaudeHomeLogin: Equatable, Sendable {
    /// Absolute folder path, exactly as Claude Code is launched with it (`CLAUDE_CONFIG_DIR`), because
    /// Claude Code hashes that value verbatim into the folder's Keychain service name.
    let directory: String
    let identityKey: String
    let email: String?
    let label: String?

    var folderSuffix: String {
        let name = URL(fileURLWithPath: directory).lastPathComponent
        return name.hasPrefix(".claude-") ? String(name.dropFirst(".claude-".count)) : name
    }

    var displayName: String { "Claude: \(email ?? folderSuffix)" }
}

/// Finds the sibling `~/.claude-*` config folders on this Mac and reads which account is signed in at
/// each, mirroring `CodexHomeScanner`. Read-only and non-interactive: the Keychain is only probed for
/// the existence of an item, never read.
struct ClaudeHomeScanner: Sendable {
    /// Claude Swap's own root (`ClaudeSwapAccount`), not a Claude Code config folder.
    static let excludedFolders: Set<String> = [".claude-swap-backup"]

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var keychain: KeychainAccessing
    var homeDirectory: @Sendable () -> URL
    var listDirectories: @Sendable (String) -> [String]

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        listDirectories: @escaping @Sendable (String) -> [String] = CodexHomeScanner.listSubdirectories
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.homeDirectory = homeDirectory
        self.listDirectories = listDirectories
    }

    /// The configured default home (`CLAUDE_CONFIG_DIR`, else `~/.claude`), standardized. A
    /// comma-separated list names no single folder, so it excludes nothing.
    func defaultHome() -> String? {
        let home = homeDirectory()
        guard let raw = environment.value(for: "CLAUDE_CONFIG_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return CodexHomeScanner.standardizedHome("~/.claude", homeDirectory: home) }
        return raw.contains(",") ? nil : CodexHomeScanner.standardizedHome(raw, homeDirectory: home)
    }

    /// Sorted `~/.claude-*` directories (symlinks never listed), minus Claude Swap's root and the
    /// configured default home.
    func candidateDirectories() -> [String] {
        let home = homeDirectory()
        let defaultHome = defaultHome()
        return listDirectories(home.path)
            .filter { $0.hasPrefix(".claude-") && !Self.excludedFolders.contains($0) }
            .sorted()
            .map { home.appendingPathComponent($0).path }
            .filter { $0 != defaultHome }
    }

    /// Every candidate folder holding a usable login, in folder order. A login whose account is
    /// `excludedIdentity` (the default home's) or already seen in an earlier folder is dropped, so
    /// one account is never two cards.
    func scan(excludingIdentity excludedIdentity: String? = nil) -> [ClaudeHomeLogin] {
        var seen = Set<String>()
        if let excludedIdentity { seen.insert(excludedIdentity) }
        var logins: [ClaudeHomeLogin] = []
        for directory in candidateDirectories() {
            guard let login = login(in: directory) else { continue }
            guard seen.insert(login.identityKey).inserted else {
                AppLog.debug(.config, "accounts: Claude home \(directory) repeats an account already found; skipping it")
                continue
            }
            logins.append(login)
        }
        return logins
    }

    private func login(in directory: String) -> ClaudeHomeLogin? {
        let text: String?
        do {
            text = try files.readTextIfPresent(directory + "/.claude.json")
        } catch {
            AppLog.warn(.config, "accounts: Claude home \(directory) has an unreadable .claude.json; skipping it")
            return nil
        }
        guard let text,
              let account = DefaultAccountObserver.claudeAccount(inStateFile: text),
              let key = DefaultAccountObserver.claudeIdentityKey(account)
        else {
            AppLog.debug(.config, "accounts: Claude home \(directory) names no signed-in account; skipping it")
            return nil
        }
        guard hasCredentials(in: directory) else {
            AppLog.debug(.config, "accounts: Claude home \(directory) has an account but no credentials; skipping it")
            return nil
        }
        return ClaudeHomeLogin(
            directory: directory, identityKey: key,
            email: account.emailAddress?.nilIfEmpty,
            label: DefaultAccountObserver.claudeIdentityLabel(account)
        )
    }

    /// A credential file with an access token, or the folder's own Keychain entry. The Keychain probe
    /// is attributes-only (no prompt); a failed probe counts as present, since the real read at
    /// refresh time reports the actual error rather than hiding a signed-in folder.
    private func hasCredentials(in directory: String) -> Bool {
        do {
            if let text = try files.readTextIfPresent(directory + "/.credentials.json"),
               let oauth = ClaudeAuthStore.parseCredentials(text)?.claudeAiOauth,
               oauth.accessToken?.isEmpty == false
            {
                return true
            }
        } catch {
            AppLog.warn(.config, "accounts: Claude home \(directory) has an unreadable .credentials.json")
        }
        let services = Self.keychainServices(
            configDirectory: directory, environment: environment, files: files, keychain: keychain
        )
        for service in services {
            switch keychain.genericPasswordExists(service: service) {
            case true?:
                return true
            case nil:
                AppLog.warn(.config, "accounts: Keychain probe for \(service) failed; treating Claude home \(directory) as signed in")
                return true
            case false?:
                continue
            }
        }
        return false
    }

    /// The Keychain services a folder's login can live under — the store's own derivation.
    static func keychainServices(
        configDirectory: String, environment: EnvironmentReading,
        files: TextFileAccessing, keychain: KeychainAccessing
    ) -> [String] {
        ClaudeAuthStore(
            environment: environment, files: files, keychain: keychain, configDirectory: configDirectory
        ).keychainServiceCandidates()
    }
}
