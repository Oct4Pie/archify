//
//  Extensions.swift
//  archify
//
//  Created by oct4pie on 6/12/24.
//

import Foundation

extension FileManager {
  func isFileReadable(atPath path: String) -> Bool {
    guard fileExists(atPath: path) else {
      return false
    }

    do {
      let fileAttributes = try attributesOfItem(atPath: path)
      let fileType = fileAttributes[FileAttributeKey.type] as? FileAttributeType
      return (fileType == .typeRegular || fileType == .typeSymbolicLink)
        && isReadableFile(atPath: path)
    } catch {
      return false
    }
  }
}

extension ProcessInfo {
  var machine: String {
    var size = 0
    sysctlbyname("hw.machine", nil, &size, nil, 0)
    var machine = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.machine", &machine, &size, nil, 0)
    return String(cString: machine)
  }
}

extension UInt64 {
  func humanReadableSize() -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(self)
    var unitIndex = 0

    while value >= 1024 && unitIndex < units.count - 1 {
      value /= 1024
      unitIndex += 1
    }

    return String(format: "%.2f %@", value, units[unitIndex])
  }
}

struct AppProgress: Identifiable {
  let id = UUID()
  let appPath: String
  var totalFiles: Int
  var processedFiles: Int

  var progress: Double {
    return totalFiles == 0 ? 0.0 : Double(processedFiles) / Double(totalFiles)
  }
}
