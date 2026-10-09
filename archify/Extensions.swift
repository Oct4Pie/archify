//
//  Extensions.swift
//  archify
//
//  Created by oct4pie on 6/12/24.
//

import SwiftUI

extension Color {
    init(nsColor: NSColor) {
        self.init(nsColor.cgColor)
    }
}

