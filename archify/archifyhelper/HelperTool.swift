//
//  HelperTool.swift
//  archifyhelper
//
//  Created by oct4pie on 6/19/24.
//

import Foundation
import Security


class HelperTool: NSObject, NSXPCListenerDelegate, HelperToolProtocol {
    static let version = Version.current
    private static let clientCodeSigningRequirement: String? = {
        guard let clients = Bundle.main.object(
            forInfoDictionaryKey: "SMAuthorizedClients"
        ) as? [String],
        let requirement = clients.first,
        !requirement.isEmpty
        else {
            return nil
        }
        return requirement
    }()
    private let listener: NSXPCListener
    private let applicationThinner = ApplicationThinner()
    private let pathValidator = HelperPathValidator(allowedDirectories: ["/Applications"])
    private let secureDirectoryRemover = SecureDirectoryRemover()
    private let supportedArchitectures: Set<String> = ["arm64", "arm64e", "x86_64"]
    /// SMJobBless copies the helper to /Library/PrivilegedHelperTools; the
    /// SMAppService helper runs from inside archify.app.
    private static let isLegacyInstallation =
        Bundle.main.executablePath == HelperService.legacyExecutablePath
    private static let notAuthorizedMessage =
        "Administrator authorization is required to change apps in /Applications."
    /// launchd starts the helper on demand, so it exits once idle. That
    /// keeps a root process from lingering, and the next request after an
    /// app update runs the updated helper rather than the old one.
    private static let idleExitDelay: TimeInterval = 30
    private let activityQueue = DispatchQueue(label: "com.oct4pie.archify.helper.activity")
    private var openConnections = 0
    private var runningOperations = 0
    private var idleExit: DispatchWorkItem?
    
    override init() {
        self.listener = NSXPCListener(
            machServiceName: HelperService.machServiceName(
                isLegacyInstallation: Self.isLegacyInstallation
            )
        )
        super.init()
        if #available(macOS 13.0, *) {
            if let requirement = Self.clientCodeSigningRequirement {
                // Foundation asks XPC to enforce this on incoming peers before
                // the listener delegate is consulted.
                self.listener.setConnectionCodeSigningRequirement(requirement)
            } else {
                NSLog("Missing SMAuthorizedClients signing requirement; helper will reject all clients.")
            }
        }
        self.listener.delegate = self
    }
    
    func run() {
        NSLog("Helper tool started.")
        self.listener.resume()
        activityQueue.async { self.scheduleIdleExitIfIdle() }
        RunLoop.current.run()
    }

    private func beginActivity(connection: Bool) {
        activityQueue.sync {
            if connection {
                openConnections += 1
            } else {
                runningOperations += 1
            }
            idleExit?.cancel()
            idleExit = nil
        }
    }

    private func endActivity(connection: Bool) {
        activityQueue.async {
            if connection {
                self.openConnections -= 1
            } else {
                self.runningOperations -= 1
            }
            self.scheduleIdleExitIfIdle()
        }
    }

    /// Runs on `activityQueue`. An operation keeps the helper alive even
    /// if its client disconnects, so a commit is never cut short.
    private func scheduleIdleExitIfIdle() {
        guard openConnections == 0, runningOperations == 0 else { return }
        idleExit?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.openConnections == 0,
                  self.runningOperations == 0
            else {
                return
            }
            NSLog("Helper tool idle; exiting.")
            exit(0)
        }
        idleExit = workItem
        activityQueue.asyncAfter(
            deadline: .now() + Self.idleExitDelay,
            execute: workItem
        )
    }
    
    
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard Self.clientCodeSigningRequirement != nil else {
            return false
        }
        if #unavailable(macOS 13.0) {
            guard validateLegacyClient(connection: newConnection) else {
                return false
            }
        }
        newConnection.exportedInterface = NSXPCInterface(with: HelperToolProtocol.self)
        newConnection.exportedObject = self
        beginActivity(connection: true)
        newConnection.invalidationHandler = { [weak self] in
            self?.endActivity(connection: true)
        }
        newConnection.resume()
        return true
    }
    
    
    
    private func validateLegacyClient(connection: NSXPCConnection) -> Bool {
        // macOS 12 predates NSXPCListener's code-signing requirement API.
        // Identify the peer by its audit token, never its PID: a process can
        // queue messages and then exec a validly signed binary under the
        // same PID, but exec changes the audit token. There is no public
        // accessor on macOS 12, so fail closed if it is unavailable.
        guard let auditToken = Self.auditToken(of: connection) else {
            NSLog("Rejected XPC client: audit token unavailable.")
            return false
        }
        var codeRef: SecCode?
        let attributes: [CFString: CFTypeRef] = [
            kSecGuestAttributeAudit: auditToken as CFData
        ]
        let codeStatus = SecCodeCopyGuestWithAttributes(
            nil,
            attributes as CFDictionary,
            SecCSFlags(),
            &codeRef
        )
        guard codeStatus == errSecSuccess, let codeRef else {
#if DEBUG
            NSLog("Unable to resolve connecting process code: \(codeStatus)")
#endif
            return false
        }

        guard let requirementString = Self.clientCodeSigningRequirement else {
            return false
        }

        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            requirementString as CFString,
            SecCSFlags(),
            &requirement
        )
        guard requirementStatus == errSecSuccess, let requirement else {
#if DEBUG
            NSLog("Unable to create client code requirement: \(requirementStatus)")
#endif
            return false
        }

        // SecCodeCopyGuestWithAttributes returns the running code object, not a
        // path-derived SecStaticCode, so the check applies to this live process
        // image rather than whatever now occupies its PID.
        let validityStatus = SecCodeCheckValidity(codeRef, SecCSFlags(), requirement)
        guard validityStatus == errSecSuccess else {
#if DEBUG
            let message = SecCopyErrorMessageString(validityStatus, nil) as String? ?? "unknown error"
            NSLog("Rejected XPC client PID \(connection.processIdentifier): \(message)")
#endif
            return false
        }

#if DEBUG
        NSLog("Validated XPC client PID \(connection.processIdentifier)")
#endif
        return true
    }

    private static func auditToken(of connection: NSXPCConnection) -> Data? {
        let selector = Selector(("auditToken"))
        guard connection.responds(to: selector),
              let value = connection.value(forKey: "auditToken") as? NSValue
        else {
            return nil
        }
        var token = audit_token_t()
        let size = MemoryLayout<audit_token_t>.size
        value.getValue(&token, size: size)
        return withUnsafeBytes(of: &token) { Data($0) }
    }

    /// Accepts only an authorization in which an administrator has
    /// authenticated for `HelperAuthorization.rightName`. The helper never
    /// shows UI, so the check fails rather than prompting.
    private func isAuthorized(_ externalForm: Data) -> Bool {
        var helperAuthorization: AuthorizationRef?
        guard AuthorizationCreate(
            nil,
            nil,
            [],
            &helperAuthorization
        ) == errAuthorizationSuccess,
        let helperAuthorization
        else {
            NSLog("Unable to create the helper authorization.")
            return false
        }
        defer { AuthorizationFree(helperAuthorization, []) }

        guard HelperAuthorization.defineRight(using: helperAuthorization) else {
            NSLog("Unable to define the Archify authorization right.")
            return false
        }

        guard externalForm.count == MemoryLayout<AuthorizationExternalForm>.size else {
            return false
        }
        var external = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &external) { externalForm.copyBytes(to: $0) }

        var clientAuthorization: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(
            &external,
            &clientAuthorization
        ) == errAuthorizationSuccess,
        let clientAuthorization
        else {
            return false
        }
        defer { AuthorizationFree(clientAuthorization, []) }

        return HelperAuthorization.copyRight(
            clientAuthorization,
            flags: [.extendRights]
        ) == errAuthorizationSuccess
    }

#if DEBUG
    func healthCheck(withReply reply: @escaping (Bool, String?) -> Void) {
        reply(true, "Archify Helper \(Self.version)")
    }
#endif

    func removeLanguageResource(
        atPath path: String,
        authorization: Data,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        guard isAuthorized(authorization) else {
            reply(false, Self.notAuthorizedMessage)
            NSLog("Rejected unauthorized language-resource removal request.")
            return
        }

        guard let target = pathValidator.languageResourceTarget(path) else {
            reply(false, "Only language resource directories inside application bundles may be removed.")
            NSLog("Rejected language-resource removal request: %@", path)
            return
        }

        beginActivity(connection: false)
        defer { endActivity(connection: false) }
        if let error = secureDirectoryRemover.remove(target) {
            // The app-protection refusal is passed through unchanged so the
            // app can explain how to allow it; other details stay in the log.
            reply(
                false,
                error == ApplicationThinner.changeNotPermittedMessage
                    ? error
                    : "Failed to remove the language resource safely."
            )
            NSLog(
                "Failed to remove language resource at %@: %@",
                target.path,
                error
            )
        } else {
            reply(true, nil)
            NSLog("Removed language resource at path: %@", target.path)
        }
    }

    func thinApplication(
        atPath path: String,
        targetArchitecture: String,
        authorization: Data,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        guard isAuthorized(authorization) else {
            reply(false, Self.notAuthorizedMessage)
            NSLog("Rejected unauthorized application-thinning request.")
            return
        }

        guard supportedArchitectures.contains(targetArchitecture) else {
            reply(false, "Unsupported target architecture.")
            NSLog("Rejected unsupported target architecture: %@", targetArchitecture)
            return
        }

        guard let target = pathValidator.applicationTarget(path) else {
            reply(false, "Only application bundles under /Applications may be thinned.")
            NSLog("Rejected application-thinning request: %@", path)
            return
        }

        beginActivity(connection: false)
        applicationThinner.thinApplication(
            atPath: target.path,
            targetArchitecture: targetArchitecture
        ) { success, error in
            defer { self.endActivity(connection: false) }
            reply(success, error)
            if success {
                NSLog("Successfully thinned application: %@", target.path)
            } else {
                NSLog("Failed to thin application %@: %@", target.path, error ?? "unknown error")
            }
        }
    }

    func retireLegacyHelper(
        authorization: Data,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        guard !Self.isLegacyInstallation else {
            reply(false, "The legacy helper cannot remove itself.")
            return
        }
        guard isAuthorized(authorization) else {
            reply(false, Self.notAuthorizedMessage)
            NSLog("Rejected unauthorized legacy-helper removal request.")
            return
        }

        beginActivity(connection: false)
        defer { endActivity(connection: false) }
        var failures: [String] = []

        // Stop the job first so launchd cannot relaunch it mid-removal.
        // Every path here is fixed; nothing comes from the client.
        _ = Self.runLaunchctl(["bootout", "system/\(HelperService.legacyLabel)"])
        if Self.runLaunchctl(["print", "system/\(HelperService.legacyLabel)"]) == 0 {
            failures.append("The legacy helper job is still loaded.")
        }

        for path in [
            HelperService.legacyLaunchDaemonPath,
            HelperService.legacyExecutablePath
        ] where unlink(path) != 0 && errno != ENOENT {
            failures.append("\(path): \(String(cString: strerror(errno)))")
        }

        if failures.isEmpty {
            NSLog("Removed the legacy Archify Helper.")
            reply(true, nil)
        } else {
            let detail = failures.joined(separator: "; ")
            NSLog("Legacy Archify Helper removal incomplete: %@", detail)
            reply(false, detail)
        }
    }

    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
