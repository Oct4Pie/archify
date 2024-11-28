//
//  Common.swift
//  archify
//
//  Created by m3hdi on 8/8/24.
//

import Foundation

func defaultMacOSApps() -> Set<String> {
    var defaultApps = Set<String>()
    
    let systemAppsPaths = [
        "/System/Applications",
        "/System/Applications/Utilities"
    ]
    
    for path in systemAppsPaths {
        if let apps = try? FileManager.default.contentsOfDirectory(atPath: path) {
            defaultApps.formUnion(apps.filter { $0.hasSuffix(".app") })
        }
    }
    
    // Add explicitly excluded apps
    defaultApps.insert("Xcode.app")
    defaultApps.insert("Safari.app")
    
    return defaultApps
}
