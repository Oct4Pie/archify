import Foundation
import ServiceManagement

class HelperToolManager {
    static let shared = HelperToolManager()
    
    private init() {}
    
    func blessHelperTool() -> Bool {
        var authRef: AuthorizationRef?
        let status = AuthorizationCreate(nil, nil, [], &authRef)
        guard status == errAuthorizationSuccess else {
            print("Authorization failed: \(status)")
            return false
        }
        
        var error: Unmanaged<CFError>?
        let blessStatus = SMJobBless(kSMDomainSystemLaunchd, "com.oct4pie.archifyhelper" as CFString, authRef, &error)
        
        if blessStatus == false {
            if let error = error?.takeRetainedValue() {
                print("SMJobBless failed: \(error)")
            }
            return false
        }
        
        return true
    }
    
    func isHelperToolInstalled() -> Bool {
        let fileManager = FileManager.default
        let helperToolPath = "/Library/PrivilegedHelperTools/com.oct4pie.archifyhelper"
        let launchDaemonPlistPath = "/Library/LaunchDaemons/com.oct4pie.archifyhelper.plist"
        
        return fileManager.fileExists(atPath: helperToolPath) && fileManager.fileExists(atPath: launchDaemonPlistPath)
    }
    
    func interactWithHelperTool(command: HelperCommand, completion: @escaping (Bool, String?) -> Void) {
        
        let connection = NSXPCConnection(machServiceName: "com.oct4pie.archifyhelper", options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperToolProtocol.self)
        connection.resume()
        
        let helper = connection.remoteObjectProxyWithErrorHandler { error in
            print("Failed to connect to helper tool: \(error)")
            completion(false, "Failed to connect to helper tool")
        } as? HelperToolProtocol
        
        switch command {
        case .removeFile(let path):
            helper?.removeFile(atPath: path, withReply: { success, errorString in
                completion(success, errorString)
                connection.invalidate()
            })
        case .duplicateApp(let appDir, let outputDir):
            helper?.duplicateApp(appDir: appDir, outputDir: outputDir, withReply: { outputAppDir, errorString in
                completion(outputAppDir != nil, errorString)
                connection.invalidate()
            })
        case .extractAndSignBinaries(let dir, let targetArch, let noSign, let noEntitlements, let appStateDict):
            helper?.extractAndSignBinaries(in: dir, targetArch: targetArch, noSign: noSign, noEntitlements: noEntitlements, appStateDict: appStateDict, withReply: { success, errorString in
                completion(success, errorString)
                connection.invalidate()
            })
        case .setFilePermissions(let path, let permissions):
            helper?.setFilePermissions(atPath: path, permissions: permissions, withReply: { success, errorString in
                completion(success, errorString)
                connection.invalidate()
            })
        case .checkFullDiskAccess:
            helper?.checkFullDiskAccess(withReply: { hasAccess in
                completion(hasAccess, hasAccess ? nil : "Full Disk Access not granted.")
                connection.invalidate()
            })
        }
    }
    
    //    func removeHelperTool() -> Bool {
    //        var authRef: AuthorizationRef?
    //        let status = AuthorizationCreate(nil, nil, [.interactionAllowed, .preAuthorize, .extendRights], &authRef)
    //
    //        guard status == errAuthorizationSuccess else {
    //            print("Authorization failed: \(status)")
    //            return false
    //        }
    //
    //        var error: Unmanaged<CFError>?
    //        let success = SMJobRemove(kSMDomainSystemLaunchd, "com.oct4pie.archifyhelper" as CFString, authRef, true, &error)
    //
    //        if !success {
    //            if let error = error?.takeRetainedValue() {
    //                print("SMJobRemove failed: \(error)")
    //            }
    //            return false
    //        }
    //
    //        return true
    //    }
    
    
}

enum HelperCommand {
    case removeFile(path: String)
    case duplicateApp(appDir: String, outputDir: String)
    case extractAndSignBinaries(dir: String, targetArch: String, noSign: Bool, noEntitlements: Bool, appStateDict: [String: Any])
    case setFilePermissions(path: String, permissions: Int)
    case checkFullDiskAccess
}
