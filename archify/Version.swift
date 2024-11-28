//
//  Version.swift
//  archify
//
//  Created by oct4pie on 8/10/24.
//

import Foundation

struct Version {
    static let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.4.0"
}
