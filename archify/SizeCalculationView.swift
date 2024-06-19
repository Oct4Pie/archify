//
//  SizeCalculationView.swift
//  archify
//
//  Created by oct4pie on 6/12/24.
//

import SwiftUI

struct SizeCalculationView: View {
    @State private var selectedAppPaths: [String] = []
    @State private var unneededArchSizes: [(String, UInt64)] = []
    @State private var showCalculationResult = false
    @State private var progress: Double = 0.0
    @State private var isCalculating = false
    @State private var currentApp: String = ""
    @State private var maxConcurrentProcesses: Int = 4
    let systemArch: String

    init() {
        systemArch = ProcessInfo.processInfo.machineArchitecture
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Unneeded Binaries")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.top, 20)
                .padding(.leading, 20)

            Text("Calculate how much unnecessary binaries your installed universal apps have")
                .font(.title3)
                .padding(.leading, 20)

            Text("Your architecture is \(systemArch)")
                .font(.callout)
                .padding(.leading, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Select Applications:")
                            .font(.headline)
                            .padding(.leading, 20)

                        Button(action: {
                            if let urls = openPanel(
                                canChooseFiles: true, canChooseDirectories: true, allowsMultipleSelection: true)
                            {
                                selectedAppPaths = urls.map { $0.path }
                            }
                        }) {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .font(.title2)
                                Text("Browse")
                                    .fontWeight(.semibold)
                            }
                            .padding()
                            .foregroundColor(.white)
                            .background(Color.blue)
                            .cornerRadius(8)
                            .padding(.horizontal, -10)
                            .padding(.vertical, -1)
                        }
                        .padding(.horizontal, 25)
                        .disabled(isCalculating) // Disable button when calculating
                    }

                    if !selectedAppPaths.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Selected Applications:")
                                .font(.headline)
                                .padding(.leading, 20)
                            List(selectedAppPaths, id: \.self) { path in
                                Text(path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .listStyle(PlainListStyle())
                            .frame(minHeight: 200)
                            .padding(.horizontal, 20)
                        }
                    } else {
                        VStack {
                            Text("No applications selected")
                                .foregroundColor(.secondary)
                                .padding(.vertical, 50)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Number of Threads:")
                            .font(.headline)
                            .padding(.leading, 20)

                        Slider(value: Binding(
                            get: { Double(self.maxConcurrentProcesses) },
                            set: { self.maxConcurrentProcesses = Int($0) }
                        ), in: 1...16, step: 1)
                        .padding(.horizontal, 20)

                        Text("Threads: \(maxConcurrentProcesses)")
                            .padding(.leading, 20)
                    }

                    Button(action: {
                        calculateUnneededArchSizes()
                    }) {
                        HStack {
                            Image(systemName: "chart.bar.xaxis")
                                .font(.title2)
                            Text("Calculate")
                                .fontWeight(.semibold)
                        }
                        .padding()
                        .foregroundColor(.white)
                        .background(Color.green)
                        .cornerRadius(8)
                        .padding(.vertical, -1)
                        .padding(.horizontal, -10)
                    }
                    .padding(.horizontal, 25)
                    .padding(.vertical, 25)
                    .disabled(isCalculating) // Disable button when calculating

                    if isCalculating {
                        VStack {
                            ProgressView(value: progress, total: 1.0)
                                .padding(.horizontal, 20)
                            Text("Processing \(self.currentApp)")
                                .foregroundColor(.secondary)
                                .padding(.top, 5)
                                .padding(.bottom, 20)
                        }
                    }

                    if showCalculationResult {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Results:")
                                .font(.headline)
                                .padding(.leading, 20)
                                .padding(.top, -10)
                            List(unneededArchSizes, id: \.0) { app in
                                HStack {
                                    Text(app.0)
                                    Spacer()
                                    Text(app.1.humanReadableSize())
                                        .foregroundColor(.secondary)
                                }
                            }
                            .listStyle(PlainListStyle())
                            .frame(minHeight: 200)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 25)
                        }
                    }
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func openPanel(canChooseFiles: Bool, canChooseDirectories: Bool, allowsMultipleSelection: Bool)
        -> [URL]?
    {
        let dialog = NSOpenPanel()
        dialog.title = "Choose directories"
        dialog.canChooseDirectories = canChooseDirectories
        dialog.canChooseFiles = canChooseFiles
        dialog.allowsMultipleSelection = allowsMultipleSelection

        if dialog.runModal() == .OK {
            return dialog.urls
        }
        return nil
    }

    func calculateUnneededArchSizes() {
        isCalculating = true
        progress = 0.0
        unneededArchSizes = []
        let totalFiles = selectedAppPaths.count
        var processedFiles = 0
        let processedFilesQueue = DispatchQueue(label: "com.universalApps.processedFilesQueue")
        let resultsQueue = DispatchQueue(label: "com.universalApps.resultsQueue", attributes: .concurrent)
        let semaphore = DispatchSemaphore(value: maxConcurrentProcesses)

        let dispatchGroup = DispatchGroup()
        let dispatchQueue = DispatchQueue.global(qos: .userInitiated)
        let finder = UniversalApps()

        for appPath in selectedAppPaths {
            dispatchGroup.enter()
            semaphore.wait()
            dispatchQueue.async {
                defer {
                    semaphore.signal()
                    dispatchGroup.leave()
                }

                let totalFilesInApp = finder.countFilesInApp(appPath: appPath)
                var processedFilesInApp = 0

                let size = finder.calculateUnneededArchSize(appPath: appPath, systemArch: systemArch, progressHandler: { _ in
                    processedFilesQueue.sync {
                        processedFilesInApp += 1
                        let progressValue = (Double(processedFiles) + (Double(processedFilesInApp) / Double(totalFilesInApp))) / Double(totalFiles)
                        DispatchQueue.main.async {
                            if processedFilesInApp % 100 == 0 {
                                self.progress = min(progressValue, 1.0)
                                self.currentApp = (appPath as NSString).lastPathComponent
                            }
                        }
                    }
                }, maxConcurrentProcesses: maxConcurrentProcesses)

                resultsQueue.sync(flags: .barrier) {
                    self.unneededArchSizes.append((appPath, size))
                }

                processedFilesQueue.sync(flags: .barrier) {
                    processedFiles += 1
                    let progressValue = Double(processedFiles) / Double(totalFiles)
                    DispatchQueue.main.async {
                        self.progress = min(progressValue, 1.0)
                    }
                }
            }
        }

        dispatchGroup.notify(queue: .main) {
            self.isCalculating = false
            self.showCalculationResult = true
            self.unneededArchSizes.sort { $0.1 > $1.1 }
        }
    }
}

extension ProcessInfo {
    var machineArchitecture: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }
}

struct SizeCalculationView_Previews: PreviewProvider {
    static var previews: some View {
        SizeCalculationView()
    }
}
