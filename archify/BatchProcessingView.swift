//
//  BatchProcessingView.swift
//  archify
//
//  Created by oct4pie on 6/20/24.
//

import SwiftUI

struct BatchProcessingView: View {
    @StateObject var appState = AppState()
    @State private var isProcessing = false
    @State private var appSizes: [(String, UInt64)] = []
    @State private var progress: Double = 0.0
    @State private var currentApp: String = ""
    @State private var selectedApps: Set<String> = []
    @State private var showAlert = false
    @State private var totalSavedSpace: UInt64 = 0

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
                .edgesIgnoringSafeArea(.all)
            
            ScrollView {
                VStack(alignment: .center, spacing: 20) {
                    Text("Batch Process")
                        .font(.title)
                        .fontWeight(.bold)
                        .padding(.bottom, 1)
                    
                    Text("Optimize your applications by removing unnecessary architectures and saving disk space.")
                        .font(.body)
                        .foregroundColor(.gray)
                        .padding(.bottom, 20)

                    if appSizes.isEmpty && !isProcessing {
                        VStack {
                            Image(systemName: "tray.full")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 100, height: 100)
                                .foregroundColor(.blue)
                                .padding(.bottom, 20)
                            
                            Text("No applications scanned yet.")
                                .font(.title2)
                                .foregroundColor(.gray)
                                .padding(.bottom, 20)
                        }
                    }
                    
                    if isProcessing {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Processing \(currentApp)...")
                                .font(.subheadline)
                                .foregroundColor(.gray)

                            ProgressView(value: progress, total: 1.0)
                                .progressViewStyle(LinearProgressViewStyle())
                        }
                        .padding(.bottom, 20)
                    }


                    Button(action: startCalculatingSizes) {
                        Label("Scan /Applications", systemImage: "chart.bar.doc.horizontal")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(15)
                            .background(isProcessing ? Color.gray : Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .padding(.horizontal, -10)
                            .padding(.vertical, -1)
                    }.padding(.horizontal, 20)
                    .disabled(isProcessing)
                    .padding(.bottom, 20)

                    
                    if !appSizes.isEmpty {
                        Text("Universal Apps:")
                            .font(.title2)
                            .padding(.bottom, 5)

                        List {
                            ForEach(appSizes, id: \.0) { app, size in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(URL(fileURLWithPath: app).lastPathComponent)
                                            .font(.headline)
                                        Text(app)
                                            .font(.subheadline)
                                            .foregroundColor(.gray)
                                        Text("Unneeded: \(size.humanReadableSize())")
                                            .font(.subheadline)
                                            .foregroundColor(.gray)
                                    }
                                    Spacer()
                                    if selectedApps.contains(app) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.blue)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if selectedApps.contains(app) {
                                        selectedApps.remove(app)
                                    } else {
                                        selectedApps.insert(app)
                                    }
                                }
                            }
                        }
                        .frame(minHeight: 300, maxHeight: 400)
                        
                        HStack {
                            Button(action: selectAllApps) {
                                Label("Select All", systemImage: "checkmark.circle.fill")
                                    .font(.headline)
                                    .padding(10)
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(10)
                                    .padding(.horizontal, -10)
                                    .padding(.vertical, -1)
                            }
                            Button(action: deselectAllApps) {
                                Label("Deselect All", systemImage: "xmark.circle.fill")
                                    .font(.headline)
                                    .padding(10)
                                    .background(Color.red)
                                    .foregroundColor(.white)
                                    .cornerRadius(10)
                                    .padding(.horizontal, -10)
                                    .padding(.vertical, -1)
                            }
                        }
                        .padding(.bottom, 5)

                        Button(action: startProcessingSelectedApps) {
                            Label("Process Apps", systemImage: "arrow.right.circle.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(15)
                                .background(selectedApps.isEmpty ? Color.gray : Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                                .padding(.horizontal, -10)
                                .padding(.vertical, -1)
                        }.padding(.horizontal, 15)
                        .disabled(selectedApps.isEmpty || isProcessing)
                        .padding(.top, 20)

                        if !appState.logMessages.isEmpty {
                            Text("Log Messages:")
                                .font(.title2)
                                .padding(.top, 20)
                            ScrollView {
                                Text(appState.logMessages)
                                    .padding()
                                    .background(Color.gray.opacity(0.1))
                                    .cornerRadius(10)
                            }
                            .frame(height: 200)
                        }

                        if totalSavedSpace > 0 {
                            Text("Saved: \(totalSavedSpace.humanReadableSize())")
                                .font(.headline)
                                .padding(.top, 10)
                        }
                    }

                    Spacer()
                }
                .padding()
            }
        }
    }

    func startCalculatingSizes() {
        isProcessing = true
        appSizes = []
        progress = 0.0
        currentApp = ""

        DispatchQueue.global(qos: .background).async {
            let universalApps = UniversalApps()
            let systemArch = self.systemArchitecture()
            universalApps.produceSortedList(systemArch: systemArch, progressHandler: { app, processed, total in
                DispatchQueue.main.async {
                    self.currentApp = URL(fileURLWithPath: app).lastPathComponent
                    self.progress = Double(processed) / Double(total)
                }
            }) { sortedAppSizes in
                DispatchQueue.main.async {
                    self.appSizes = sortedAppSizes
                    self.isProcessing = false
                }
            }
        }
    }

    func startProcessingSelectedApps() {
        isProcessing = true
        appState.isProcessing = true
        appState.logMessages = ""
        totalSavedSpace = 0

        guard HelperToolManager.shared.isHelperToolInstalled() || HelperToolManager.shared.blessHelperTool() else {
            print("Failed to install helper tool.")
            return
        }

        DispatchQueue.global(qos: .background).async {
            let appStateDict = appState.toDictionary()
            let group = DispatchGroup()

            for app in selectedApps {
                group.enter()
                HelperToolManager.shared.interactWithHelperTool(command: .extractAndSignBinaries(dir: app, targetArch: systemArchitecture(), noSign: true, noEntitlements: true, appStateDict: appStateDict)) { success, errorString in
                    if success {
                        DispatchQueue.main.async {
                            // Update the total saved space and remove the app from appSizes
                            if let index = self.appSizes.firstIndex(where: { $0.0 == app }) {
                                self.totalSavedSpace += self.appSizes[index].1
                                self.appSizes.remove(at: index)
                                self.selectedApps.remove(app)
                            }
                        }
                        print("Processed \(app) successfully")
                    } else {
                        print("Failed to process \(app): \(errorString ?? "Unknown error")")
                    }
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                self.isProcessing = false
                self.appState.isProcessing = false
            }
        }
    }

    func selectAllApps() {
        selectedApps = Set(appSizes.map { $0.0 })
    }

    func deselectAllApps() {
        selectedApps.removeAll()
    }

    func systemArchitecture() -> String {
        let process = Process()
        process.launchPath = "/usr/bin/uname"
        process.arguments = ["-m"]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                return output
            }
        } catch {
            return "Unknown"
        }

        return "Unknown"
    }
}

struct BatchProcessingView_Previews: PreviewProvider {
    static var previews: some View {
        BatchProcessingView()
    }
}
