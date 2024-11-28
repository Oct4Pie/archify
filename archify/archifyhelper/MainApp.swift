//
//  MainApp.swift
//  archifyhelper
//
//  Created by oct4pie on 6/19/24.
//

import Foundation

func removeFile(atPath path: String) {
    let connection = NSXPCConnection(machServiceName: "com.oct4pie.archifyhelper", options: .privileged)
    connection.remoteObjectInterface = NSXPCInterface(with: HelperToolProtocol.self)
    connection.resume()
    
    NSLog("Attempting to connect to helper tool.")
    let helper = connection.remoteObjectProxyWithErrorHandler { error in
        NSLog("Failed to connect to helper tool: \(error)")
    } as? HelperToolProtocol
    
    helper?.removeFile(atPath: path, withReply: { success, errorString in
        if success {
            NSLog("File removed successfully.")
        } else {
            if let errorString = errorString {
                NSLog("Failed to remove file: \(errorString)")
            } else {
                NSLog("Failed to remove file.")
            }
        }
        connection.invalidate()
    })
}

func extractAndSignBinaries(in dir: String, targetArch: String, noSign: Bool, noEntitlements: Bool, appState: AppState, completion: @escaping (Bool) -> Void) {
    let connection = NSXPCConnection(machServiceName: "com.oct4pie.archifyhelper", options: .privileged)
    connection.remoteObjectInterface = NSXPCInterface(with: HelperToolProtocol.self)
    connection.resume()
    
    NSLog("Attempting to connect to helper tool.")
    let helper = connection.remoteObjectProxyWithErrorHandler { error in
        NSLog("Failed to connect to helper tool: \(error)")
        completion(false)
    } as? HelperToolProtocol
    
    let appStateDict = appState.toDictionary()
    
    helper?.extractAndSignBinaries(in: dir, targetArch: targetArch, noSign: noSign, noEntitlements: noEntitlements, appStateDict: appStateDict, withReply: { success, errorString in
        if success {
            NSLog("Binaries extracted and signed successfully.")
            completion(true)
        } else {
            if let errorString = errorString {
                NSLog("Failed to extract and sign binaries: \(errorString)")
            } else {
                NSLog("Failed to extract and sign binaries.")
            }
            completion(false)
        }
        connection.invalidate()
    })
}
