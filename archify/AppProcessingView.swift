//
//  AppProcessingView.swift
//  archify
//
//  Created by oct4pie on 6/20/24.
//

import SwiftUI

struct AppProcessingView: View {
    @EnvironmentObject var appState: AppState
    @State private var showAlert = false
    @State private var isHoveringProcess = false
    
    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).edgesIgnoringSafeArea(.all)
            
            ScrollView {
                VStack(spacing: 30) {
                    headerSection
                    configurationSection
                    actionSection
                    if appState.isProcessing {
                        progressSection
                    }
                    if hasResults {
                        resultsSection
                    }
                    logSection
                }
                .padding()
            }
        }
        .alert(isPresented: $showAlert) {
            Alert(
                title: Text("Warning"),
                message: Text("Signing is enabled but ldid path is not provided. Please provide the ldid path."),
                dismissButton: .default(Text("OK"))
            )
        }
    }
    
    // MARK: - Sections
    
    var headerSection: some View {
        VStack(spacing: 10) {
            Image(systemName: "gearshape.2.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 60, height: 60)
                .foregroundColor(.blue)
            Text("App Processor")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("Optimize your universal apps with ease")
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(15)
        .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
    }
    
    var configurationSection: some View {
        VStack(spacing: 20) {
            inputOutputSection
            architectureSection
            signingSection
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(15)
        .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
    }
    
    var actionSection: some View {
        processButton
    }
    
    var inputOutputSection: some View {
        VStack(spacing: 20) {
            fileSelectionView(title: "Input App", systemImage: "folder.fill", path: $appState.inputDir, canChooseFiles: true)
            fileSelectionView(title: "Output Location", systemImage: "folder.badge.plus", path: $appState.outputDir, canChooseFiles: false)
        }
    }
    
    func fileSelectionView(title: String, systemImage: String, path: Binding<String>, canChooseFiles: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            HStack {
                TextField("Select path", text: path)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                Button("Choose") {
                    if let url = openPanel(canChooseFiles: canChooseFiles, canChooseDirectories: !canChooseFiles) {
                        path.wrappedValue = url.path
                    }
                }
                .buttonStyle(BlueButtonStyle())
                .background(Color.blue)
            }
        }
    }
    
    var architectureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Target Architecture")
                .font(.headline)
            Picker("Architecture", selection: $appState.selectedArch) {
                ForEach(appState.architectures, id: \.self) {
                    Text($0)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            .onAppear {
                appState.selectedArch = ProcessInfo.processInfo.machineArchitecture
            }
        }
    }
    
    var signingSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Signing Options")
                .font(.headline)
            signingOptions
        }
    }
    
    var signingOptions: some View {
        Group {
            Toggle("Sign binaries with ldid", isOn: $appState.useLDID)
                .onChange(of: appState.useLDID) { newValue in
                    if newValue { appState.useCodesign = false }
                }
            if appState.useLDID {
                ldidOptions
            }
            Toggle("Ad-hoc codesign", isOn: $appState.useCodesign)
                .onChange(of: appState.useCodesign) { newValue in
                    if newValue { appState.useLDID = false }
                }
            if appState.useCodesign {
                Toggle("Use entitlements", isOn: $appState.entitlements)
                    .padding(.leading, 20)
            }
            Toggle("Launch app (cache)", isOn: $appState.launchSign)
        }
    }
    
    var ldidOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("LDID Path", text: $appState.ldidPath)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onAppear() {
                        appState.ldidPath = appState.findLdid() ?? ""
                    }
                Button("Browse") {
                    if let url = openPanel(canChooseFiles: true, canChooseDirectories: false) {
                        appState.ldidPath = url.path
                    }
                }
                .buttonStyle(BlueButtonStyle())
                .background(Color.blue)
            }
            Toggle("Include entitlements", isOn: $appState.entitlements)
                .padding(.leading, 20)
        }
    }
    
    var processButton: some View {
        Button(action: startProcessing) {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Process App")
            }
            .font(.headline)
            .frame(maxWidth: 250)
            .padding()
            .background(appState.isProcessing ? Color.gray : Color.blue)
            .foregroundColor(.white)
            .cornerRadius(10)
            .padding(.horizontal, -10)
            .padding(.vertical, -2)
        }
        .disabled(appState.isProcessing)
        .scaleEffect(isHoveringProcess ? 1.01 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isHoveringProcess)
        .onHover { hovering in
            isHoveringProcess = hovering
        }
        .shadow(color: Color.black.opacity(0.2), radius: 5, x: 0, y: 3)
    }
    
    var progressSection: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Processing...")
                .font(.headline)
        }.padding(.vertical, 30)
            .frame(maxWidth: .infinity)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(15)
            .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
        
    }
    
    var resultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Results")
                .font(.headline)
            if appState.initialAppSize != 0 {
                Text("Initial App Size: \(appState.initialAppSize.humanReadableSize())")
            }
            if appState.finalAppSize != 0 {
                Text("Final App Size: \(appState.finalAppSize.humanReadableSize())")
            }
            if appState.initialAppSize != 0 && appState.finalAppSize != 0 {
                let change = appState.initialAppSize - appState.finalAppSize
                let pchange = String(format: "%.2f%%", 100 - (Double(appState.finalAppSize) / Double(appState.initialAppSize) * 100))
                Text("Saved: \(change.humanReadableSize()) (\(pchange))")
                    .foregroundColor(.green)
                    .fontWeight(.bold)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(15)
        .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
    }
    
    var logSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Log")
                .font(.headline)
            ScrollView {
                Text(appState.logMessages)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 200)
            .padding(10)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(10)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(15)
        .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
    }
    
    // MARK: - Logic
    
    var hasResults: Bool {
        appState.initialAppSize != 0 || appState.finalAppSize != 0
    }
    
    func startProcessing() {
        if appState.useLDID && appState.ldidPath.isEmpty {
            showAlert = true
        } else {
            appState.initialAppSize = 0
            appState.finalAppSize = 0
            appState.logMessages = ""
            appState.isProcessing = true
            appState.processApp()
        }
    }
    
    func openPanel(canChooseFiles: Bool, canChooseDirectories: Bool) -> URL? {
        let dialog = NSOpenPanel()
        dialog.title = "Choose a directory or file"
        dialog.canChooseDirectories = canChooseDirectories
        dialog.canChooseFiles = canChooseFiles
        dialog.allowsMultipleSelection = false
        dialog.allowedContentTypes = [.application]
        
        if dialog.runModal() == .OK {
            return dialog.url
        }
        return nil
    }
}

struct BlueButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundColor(.white)
            .cornerRadius(8)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
    }
}

struct AppProcessingView_Previews: PreviewProvider {
    static var previews: some View {
        AppProcessingView()
            .environmentObject(AppState())
    }
}
