//
//  HelperToolProtocol.swift
//  archifyhelper
//
//  Created by oct4pie on 6/19/24.
//

import Foundation

@objc protocol HelperToolProtocol {
    func removeFile(atPath path: String, withReply reply: @escaping (Bool, String?) -> Void)
    func duplicateApp(appDir: String, outputDir: String, withReply reply: @escaping (String?, String?) -> Void)
    func extractAndSignBinaries(in dir: String, targetArch: String, noSign: Bool, noEntitlements: Bool, appStateDict: [String: Any], withReply reply: @escaping (Bool, String?) -> Void)
    func setFilePermissions(atPath path: String, permissions: Int, withReply reply: @escaping (Bool, String?) -> Void)
}
