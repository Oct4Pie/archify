import AppKit
import Foundation
import Security
import ServiceManagement

enum HelperServiceState: Equatable {
    case ready
    case needsApproval
    case notSetUp
    case legacyReady
    case unavailableForAdHocDebug
    case unknown
}

final class HelperToolManager {
    static let shared = HelperToolManager()

    /// SMJobBless identifies the helper by its legacy label.
    private let helperIdentifier = HelperService.legacyLabel
    private let launchDaemonPlistName = "\(HelperService.label).plist"
    private let installedHelperPath = HelperService.legacyExecutablePath
    private let launchDaemonPlistPath = HelperService.legacyLaunchDaemonPath
    /// Set once the legacy helper has been removed (or none was found) so the
    /// check runs at most once per launch.
    private var legacyHelperRetired = false

    /// Reported when the user cancels the administrator prompt. Callers stop
    /// the remaining work instead of prompting again for every item.
    static let authorizationCanceledMessage =
        "Administrator authorization was canceled."

    /// Serializes prompts and owns `privilegedAuthorization`.
    private let authorizationQueue = DispatchQueue(
        label: "com.oct4pie.archify.authorization"
    )
    /// Kept for the app's lifetime so the administrator credential is reused
    /// until the right's timeout expires instead of prompting per item.
    private var privilegedAuthorization: AuthorizationRef?

    private init() {}

    func serviceState() -> HelperServiceState {
#if DEBUG
        guard debugBuildCanUsePrivilegedHelper() else {
            return .unavailableForAdHocDebug
        }
#endif

        if #available(macOS 13.0, *) {
            // A legacy helper from Archify 1.4 is never used here. It sits
            // outside archify.app, so macOS doesn't attribute it to archify
            // and Full Disk Access for archify can't apply to it. It is
            // removed in the background once the new helper is approved.
            switch SMAppService.daemon(plistName: launchDaemonPlistName).status {
            case .enabled:
                return .ready
            case .requiresApproval:
                return .needsApproval
            case .notRegistered, .notFound:
                return .notSetUp
            @unknown default:
                return .unknown
            }
        }

        return isLegacyHelperInstalled() ? .legacyReady : .notSetUp
    }

    func currentTeamIdentifier() -> String? {
        var selfCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &selfCode) == errSecSuccess,
              let selfCode
        else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(
            selfCode,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
        let staticCode
        else {
            return nil
        }

        var signingInfo: CFDictionary?
        let status = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInfo
        )
        guard status == errSecSuccess,
              let info = signingInfo as? [CFString: Any]
        else {
            return nil
        }

        return info[kSecCodeInfoTeamIdentifier] as? String
    }

    func openApprovalSettings() {
        if #available(macOS 13.0, *) {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    /// Privacy & Security → Full Disk Access.
    ///
    /// macOS protects notarized apps from changes by other developers'
    /// software. App Management cannot lift that for Archify Helper because
    /// it is granted per user and the helper runs as root; Full Disk Access
    /// is system-wide, includes App Management, and macOS attributes the
    /// helper (inside archify.app) to archify, so archify's switch applies.
    func openFullDiskAccessSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    /// The app's name as it appears in System Settings lists.
    static var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Archify"
    }

    /// Whether a helper reply means macOS app protection refused the change.
    static func isProtectedAppRefusal(_ message: String?) -> Bool {
        message == ApplicationThinner.changeNotPermittedMessage
    }

    func unavailableMessage() -> String {
        switch serviceState() {
        case .needsApproval:
            return "Approve Archify Helper in System Settings, then try again."
        case .unavailableForAdHocDebug:
            return "Administrator features are disabled in this development build."
        case .notSetUp, .unknown:
            return "Archify Helper isn’t available. Check Settings → Helper and try again."
        case .ready, .legacyReady:
            return "Archify Helper couldn’t complete setup. Try again."
        }
    }

    func ensureHelperToolInstalled() -> Bool {
#if DEBUG
        guard debugBuildCanUsePrivilegedHelper() else {
            print(
                "Privileged helper is disabled for ad hoc Debug builds. "
                + "Use scripts/build-privileged-debug.sh to create a locally "
                + "identified Debug build for helper testing."
            )
            return false
        }
#endif
        if #available(macOS 13.0, *) {
            return ensureModernHelperTool()
        } else {
            return ensureLegacyHelperTool()
        }
    }

#if DEBUG
    private func debugBuildCanUsePrivilegedHelper() -> Bool {
        guard let teamIdentifier = currentTeamIdentifier() else {
            return false
        }
        return !teamIdentifier.isEmpty
    }

    func testPrivilegedHelperConnection(
        completion: @escaping (Bool, String?) -> Void
    ) {
        guard ensureHelperToolInstalled() else {
            completion(
                false,
                "The helper is not registered yet. If macOS requested "
                    + "approval, approve Archify Helper in System Settings "
                    + "and run the test again."
            )
            return
        }

        interactWithHelperTool(
            command: .healthCheck,
            completion: completion
        )
    }
#endif

    @available(macOS 13.0, *)
    private func ensureModernHelperTool() -> Bool {
        let service = SMAppService.daemon(plistName: launchDaemonPlistName)

        switch service.status {
        case .enabled:
            return true

        case .requiresApproval:
            print("Archify Helper requires approval in System Settings.")
            return false

        case .notRegistered, .notFound:
            // The SMAppService helper has its own launchd label, so it can be
            // registered and used right away even while a legacy SMJobBless
            // helper is still loaded; no restart or logout is needed.
            do {
                try service.register()
            } catch {
                // Registration of a LaunchDaemon may intentionally stop here
                // pending admin approval. Prefer the service status over an
                // error-code guess because ServiceManagement owns that state.
                if service.status == .requiresApproval {
                    print("Archify Helper registration is awaiting admin approval.")
                } else {
                    print("SMAppService registration failed: \(error)")
                }
                return false
            }

            switch service.status {
            case .enabled:
                return true
            case .requiresApproval:
                print("Archify Helper registration is awaiting admin approval.")
                return false
            case .notRegistered, .notFound:
                print("Archify Helper did not become registered after SMAppService.register().")
                return false
            @unknown default:
                print("Archify Helper has an unknown SMAppService status.")
                return false
            }

        @unknown default:
            print("Archify Helper has an unknown SMAppService status.")
            return false
        }
    }

    private func ensureLegacyHelperTool() -> Bool {
        guard isLegacyHelperInstalled() else {
            return blessLegacyHelperTool()
        }

        if HelperVersionUtilities.needsRefresh(
            installedVersion: helperVersion(atPath: installedHelperPath),
            bundledVersion: bundledHelperVersion()
        ) {
            return blessLegacyHelperTool()
        }

        return true
    }

    private func blessLegacyHelperTool() -> Bool {
        guard let authRef = createAuthorizationReference() else {
            return false
        }
        defer { AuthorizationFree(authRef, []) }

        var error: Unmanaged<CFError>?
        let success = SMJobBless(
            kSMDomainSystemLaunchd,
            helperIdentifier as CFString,
            authRef,
            &error
        )

        guard success else {
            if let error = error?.takeRetainedValue() {
                print("SMJobBless failed: \(error)")
            }
            return false
        }

        return true
    }

    private func createAuthorizationReference() -> AuthorizationRef? {
        var authRef: AuthorizationRef?
        let status = AuthorizationCreate(
            nil,
            nil,
            [.interactionAllowed, .extendRights, .preAuthorize],
            &authRef
        )
        guard status == errAuthorizationSuccess else {
            print("Authorization failed: \(status)")
            return nil
        }
        return authRef
    }

    private func bundledHelperVersion() -> String? {
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchServices", isDirectory: true)
            .appendingPathComponent(helperIdentifier, isDirectory: false)
        return helperVersion(atPath: helperURL.path)
    }

    private func helperVersion(atPath path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path),
              let info = CFBundleCopyInfoDictionaryForURL(
                URL(fileURLWithPath: path) as CFURL
              ) as? [String: Any]
        else {
            return nil
        }
        return info["CFBundleVersion"] as? String
    }

    private func isLegacyHelperInstalled() -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: installedHelperPath)
            && fileManager.fileExists(atPath: launchDaemonPlistPath)
    }

    func interactWithHelperTool(
        command: HelperCommand,
        completion: @escaping (Bool, String?) -> Void
    ) {
#if DEBUG
        if case .healthCheck = command {
            sendToHelperTool(command, authorization: Data(), completion: completion)
            return
        }
#endif
        authorizationQueue.async {
            switch self.authorizePrivilegedChange() {
            case .success(let authorization):
                self.retireLegacyHelperIfNeeded(authorization: authorization)
                self.sendToHelperTool(
                    command,
                    authorization: authorization,
                    completion: completion
                )
            case .failure(let message):
                completion(false, message)
            }
        }
    }

    /// Removes an Archify 1.4 SMJobBless helper using the new helper. Runs
    /// alongside the user's operation and never blocks it: a failure is
    /// logged and retried on the next launch. Runs on `authorizationQueue`.
    private func retireLegacyHelperIfNeeded(authorization: Data) {
        guard #available(macOS 13.0, *), !legacyHelperRetired else { return }
        guard isLegacyHelperInstalled() || isLegacyHelperJobLoaded() else {
            legacyHelperRetired = true
            return
        }

        sendToHelperTool(.retireLegacyHelper, authorization: authorization) { success, error in
            if success {
                self.authorizationQueue.async {
                    self.legacyHelperRetired = true
                }
            } else {
                print("Legacy Archify Helper not removed yet: \(error ?? "unknown error")")
            }
        }
    }

    private func isLegacyHelperJobLoaded() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(HelperService.legacyLabel)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private enum AuthorizationResult {
        case success(Data)
        case failure(String)
    }

    /// Asks for administrator authentication if the cached credential has
    /// expired, then returns it in a form the helper can verify. Runs on
    /// `authorizationQueue`; the prompt is shown by macOS, not on our
    /// main thread.
    private func authorizePrivilegedChange() -> AuthorizationResult {
        if privilegedAuthorization == nil {
            var authorization: AuthorizationRef?
            guard AuthorizationCreate(
                nil,
                nil,
                [],
                &authorization
            ) == errAuthorizationSuccess,
            let authorization
            else {
                return .failure("Archify could not start administrator authorization.")
            }
            privilegedAuthorization = authorization
        }
        guard let authorization = privilegedAuthorization else {
            return .failure("Archify could not start administrator authorization.")
        }

        // Adding a right that does not exist yet needs no authentication.
        // The helper rewrites the definition as root before checking it, so
        // a definition planted by another process cannot weaken the check.
        if AuthorizationRightGet(HelperAuthorization.rightName, nil)
            != errAuthorizationSuccess {
            HelperAuthorization.defineRight(using: authorization)
        }

        let status = HelperAuthorization.copyRight(
            authorization,
            flags: [.interactionAllowed, .extendRights, .preAuthorize]
        )
        switch status {
        case errAuthorizationSuccess:
            break
        case errAuthorizationCanceled:
            return .failure(Self.authorizationCanceledMessage)
        default:
            return .failure("Administrator authorization failed (\(status)).")
        }

        var external = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(
            authorization,
            &external
        ) == errAuthorizationSuccess else {
            return .failure("Archify could not pass the authorization to its helper.")
        }
        return .success(withUnsafeBytes(of: &external) { Data($0) })
    }

    private func sendToHelperTool(
        _ command: HelperCommand,
        authorization: Data,
        completion: @escaping (Bool, String?) -> Void
    ) {
        let connection = NSXPCConnection(
            machServiceName: HelperService.currentLabel,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: HelperToolProtocol.self)
        connection.resume()

        guard let helper = connection.remoteObjectProxyWithErrorHandler({ error in
            print("Failed to connect to helper tool: \(error)")
            completion(false, "Failed to connect to helper tool")
            connection.invalidate()
        }) as? HelperToolProtocol else {
            connection.invalidate()
            completion(false, "Failed to create helper proxy")
            return
        }

        switch command {
#if DEBUG
        case .healthCheck:
            helper.healthCheck { success, message in
                completion(success, message)
                connection.invalidate()
            }
#endif
        case .removeLanguageResource(let path):
            helper.removeLanguageResource(
                atPath: path,
                authorization: authorization
            ) { success, errorString in
                completion(success, errorString)
                connection.invalidate()
            }

        case .retireLegacyHelper:
            helper.retireLegacyHelper(
                authorization: authorization
            ) { success, errorString in
                completion(success, errorString)
                connection.invalidate()
            }

        case .thinApplication(let path, let targetArchitecture):
            helper.thinApplication(
                atPath: path,
                targetArchitecture: targetArchitecture,
                authorization: authorization
            ) { success, errorString in
                completion(success, errorString)
                connection.invalidate()
            }
        }
    }
}

enum HelperCommand {
#if DEBUG
    case healthCheck
#endif
    case removeLanguageResource(path: String)
    case thinApplication(path: String, targetArchitecture: String)
    /// Internal: issued by HelperToolManager during migration.
    case retireLegacyHelper
}

/// Something that stops Archify Helper from doing protected work, together
/// with what the user can do about it.
enum HelperAccessIssue: Identifiable, Equatable {
    /// macOS 13+: the helper is registered but waiting for approval in
    /// Login Items & Extensions.
    case needsApproval
    /// macOS app protection refused a change; Full Disk Access lifts it.
    case fullDiskAccessNeeded
    case unavailable(String)

    var id: String {
        switch self {
        case .needsApproval: return "needsApproval"
        case .fullDiskAccessNeeded: return "fullDiskAccessNeeded"
        case .unavailable(let message): return "unavailable:\(message)"
        }
    }
}

/// Presents helper setup and permission guidance, then resumes the work
/// that needed it. Use from the main thread.
final class HelperAccess: ObservableObject {
    static let shared = HelperAccess()

    @Published private(set) var issue: HelperAccessIssue?
    private var retry: (() -> Void)?

    private init() {}

    /// Installs or registers the helper if needed. Returns true when it is
    /// ready now; otherwise shows the matching guidance and calls `retry`
    /// once the user has resolved it.
    func ensureReady(retry: @escaping () -> Void) -> Bool {
        let manager = HelperToolManager.shared
        if manager.ensureHelperToolInstalled() {
            return true
        }
        if manager.serviceState() == .needsApproval {
            present(.needsApproval, retry: retry)
        } else {
            present(.unavailable(manager.unavailableMessage()), retry: nil)
        }
        return false
    }

    func present(_ issue: HelperAccessIssue, retry: (() -> Void)?) {
        self.retry = retry
        self.issue = issue
    }

    func dismiss() {
        issue = nil
        retry = nil
    }

    /// Dismisses the guidance and resumes the interrupted work.
    func resolve() {
        let retry = self.retry
        dismiss()
        retry?()
    }

    var canRetry: Bool { retry != nil }
}
