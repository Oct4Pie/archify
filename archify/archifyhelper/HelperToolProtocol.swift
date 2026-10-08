//
//  HelperToolProtocol.swift
//  archifyhelper
//
//  Created by oct4pie on 6/19/24.
//

import Foundation
import Security

/// launchd identities of Archify Helper.
///
/// macOS 13+ registers the helper with SMAppService under `label`. macOS 12
/// and installs from Archify 1.4 and earlier use SMJobBless under
/// `legacyLabel`, which copies the helper out of the app. The labels differ so
/// that the two can never contend for one launchd job, which lets a new
/// helper start immediately while the legacy one is removed in the
/// background, with no restart or logout.
enum HelperService {
    static let label = "com.oct4pie.archify.helper"
    static let legacyLabel = "com.oct4pie.archifyhelper"
    static let legacyExecutablePath = "/Library/PrivilegedHelperTools/com.oct4pie.archifyhelper"
    static let legacyLaunchDaemonPath = "/Library/LaunchDaemons/com.oct4pie.archifyhelper.plist"

    /// The label the app uses on this version of macOS.
    static var currentLabel: String {
        if #available(macOS 13.0, *) {
            return label
        }
        return legacyLabel
    }

    /// The Mach service this process should listen on or connect to.
    static func machServiceName(isLegacyInstallation: Bool) -> String {
        isLegacyInstallation ? legacyLabel : label
    }
}

@objc protocol HelperToolProtocol {
#if DEBUG
    func healthCheck(withReply reply: @escaping (Bool, String?) -> Void)
#endif
    /// `authorization` is an `AuthorizationExternalForm` holding
    /// `HelperAuthorization.rightName`.
    func removeLanguageResource(
        atPath path: String,
        authorization: Data,
        withReply reply: @escaping (Bool, String?) -> Void
    )
    /// `authorization` is an `AuthorizationExternalForm` holding
    /// `HelperAuthorization.rightName`.
    func thinApplication(
        atPath path: String,
        targetArchitecture: String,
        authorization: Data,
        withReply reply: @escaping (Bool, String?) -> Void
    )
    /// Stops and deletes the legacy SMJobBless helper at its fixed paths.
    /// Only the SMAppService helper performs this.
    func retireLegacyHelper(
        authorization: Data,
        withReply reply: @escaping (Bool, String?) -> Void
    )
}

/// The administrator authorization every privileged helper operation
/// requires. The app obtains it interactively; the helper re-checks it
/// without interaction before changing anything.
enum HelperAuthorization {
    static let rightName = "com.oct4pie.archify.modify-applications"

    static let prompt = "Archify wants to change apps in your Applications folder."

    /// An administrator must authenticate. The credential stays in the
    /// app's own authorization for five minutes, so one batch run normally
    /// needs one prompt; it is never shared with other processes or granted
    /// to root without authentication.
    static let ruleDefinition: [String: Any] = [
        "class": "user",
        "group": "admin",
        "authenticate-user": true,
        "allow-root": false,
        "session-owner": false,
        "shared": false,
        "timeout": 300,
        "tries": 10000,
        "comment": "Used by Archify to thin apps and remove language files in /Applications."
    ]

    /// Writes the expected rule. Any process may add a right that does not
    /// exist yet, so the helper rewrites it as root before every check
    /// rather than trusting an existing definition.
    @discardableResult
    static func defineRight(using authorization: AuthorizationRef) -> Bool {
        AuthorizationRightSet(
            authorization,
            rightName,
            ruleDefinition as CFDictionary,
            prompt as CFString,
            nil,
            nil
        ) == errAuthorizationSuccess
    }

    static func copyRight(
        _ authorization: AuthorizationRef,
        flags: AuthorizationFlags
    ) -> OSStatus {
        rightName.withCString { name in
            var item = AuthorizationItem(
                name: name,
                valueLength: 0,
                value: nil,
                flags: 0
            )
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                return AuthorizationCopyRights(
                    authorization,
                    &rights,
                    nil,
                    flags,
                    nil
                )
            }
        }
    }
}
