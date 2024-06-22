//
//  FileOperationsManager.swift
//  archify
//
//  Created by oct4pie on 6/20/24.
//

import Foundation
import AppKit

class FileOperationsManager {
    static let shared = FileOperationsManager()

    private init() {}

    func removeFile(atPath path: String, completion: @escaping (Bool, String?) -> Void) {
        do {
            try FileManager.default.removeItem(atPath: path)
            completion(true, nil)
        } catch {
            completion(false, error.localizedDescription)
        }
    }

    func removeFiles(paths: [String], progressUpdate: @escaping (Double) -> Void, completion: @escaping (Bool, String?) -> Void) {
        let totalCount = paths.count
        var removedCount = 0

        DispatchQueue.global(qos: .background).async {
            for path in paths {
                self.removeFile(atPath: path) { success, error in
                    if success {
                        removedCount += 1
                    } else {
                        completion(false, error)
                        return
                    }
                    DispatchQueue.main.async {
                        progressUpdate(Double(removedCount) / Double(totalCount))
                    }
                }
            }

            DispatchQueue.main.async {
                completion(true, nil)
            }
        }
    }
}

