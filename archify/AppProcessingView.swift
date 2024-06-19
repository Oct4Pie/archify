//
//  AppProcessingView.swift
//  archify
//
//  Created by oct4pie on 6/12/24.
//

import SwiftUI

struct AppProcessingView: View {
  @StateObject var appState = AppState()
  @State private var showAlert = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Text("Archify")
          .font(.largeTitle)
          .fontWeight(.bold)
          .padding(.bottom, 20)

        Text("Select a universal app that you want to clean up and where to output it")
          .font(.title3)

        HStack {
          TextField("Input App", text: $appState.inputDir)
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .padding(.trailing, 10)
          Button("Choose") {
            if let url = openPanel(canChooseFiles: true, canChooseDirectories: true) {
              appState.inputDir = url.path
            }
          }
          .buttonStyle(DefaultButtonStyle())
        }

        HStack {
          TextField("Output Location", text: $appState.outputDir)
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .padding(.trailing, 10)
          Button("Choose") {
            if let url = openPanel(canChooseFiles: false, canChooseDirectories: true) {
              appState.outputDir = url.path
            }
          }
          .buttonStyle(DefaultButtonStyle())
        }

        Picker("Architecture", selection: $appState.selectedArch) {
          ForEach(appState.architectures, id: \.self) {
            Text($0)
          }
        }
        .pickerStyle(SegmentedPickerStyle())
        .padding(.vertical, 10)
        .onAppear {
          appState.selectedArch = systemArchitecture()
        }

        Toggle("Sign binaries with ldid", isOn: $appState.useLDID)
          .padding(.vertical, 5)
          .onChange(of: appState.useLDID) { newValue in
            if newValue {
              appState.useCodesign = false
            }
          }

        if appState.useLDID {
          HStack {
            TextField("LDID Path", text: $appState.ldidPath)
              .textFieldStyle(RoundedBorderTextFieldStyle())
              .padding(.trailing, 10)
            Button("Browse") {
              if let url = openPanel(canChooseFiles: true, canChooseDirectories: false) {
                appState.ldidPath = url.path
              }
            }
            .buttonStyle(DefaultButtonStyle())
          }
          .onAppear {
            if let ldidPath = appState.findLdid() {
              appState.ldidPath = ldidPath
            }
          }

          Toggle("Include entitlements", isOn: $appState.entitlements)
            .padding(.vertical, 5)
            .padding(.horizontal, 20)
            .onChange(of: appState.useCodesign) { newValue in
              if newValue {
                appState.useCodesign = false
              }
            }
        }

        Toggle("Ad-hoc codesign", isOn: $appState.useCodesign)
          .padding(.vertical, 5)
          .onChange(of: appState.useCodesign) { newValue in
            if newValue {
              appState.useLDID = false
            }
          }

        if appState.useCodesign {
          Toggle("Use entitlements", isOn: $appState.entitlements)
            .padding(.vertical, 5)
            .padding(.horizontal, 20)
        }

        Toggle("Launch app (cache)", isOn: $appState.launchSign)
          .padding(.vertical, 5)

        Button(action: startProcessing) {
          Text("Process")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding()
            .background(appState.isProcessing ? Color.gray : Color.blue)
            .foregroundColor(.white)
            .cornerRadius(10)
            .padding(.horizontal, -10)
            .padding(.vertical, -1)

        }.disabled(appState.isProcessing)
          .padding(.vertical, 20)
          .alert(isPresented: $showAlert) {
            Alert(
              title: Text("Warning"),
              message: Text(
                "Signing is enabled but ldid path is not provided. Please provide the ldid path."),
              dismissButton: .default(Text("OK"))
            )
          }

        if appState.initialAppSize != 0 {
          Text("Initial App Size: \(appState.initialAppSize.humanReadableSize())")
            .padding(.top, 10)
        }
        if appState.initialAppSize != 0 {
          Text("Final App Size: \(appState.finalAppSize.humanReadableSize())")
            .padding(.bottom, 10)
        }

        if appState.initialAppSize != 0 && appState.finalAppSize != 0 {
          let change = appState.initialAppSize - appState.finalAppSize
          let pchange = String(
            format: "%.2f%%",
            100 - (Double(appState.finalAppSize) / Double(appState.initialAppSize) * 100))
          Text("Saved: \(change.humanReadableSize()), \(pchange)")
            .padding(.bottom, 10)
        }

        ScrollView {
          Text(appState.logMessages)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .frame(height: 200)
        .border(Color.gray, width: 1)
        .background(Color.gray.opacity(0.1))
      }
      .padding()
      .frame(maxWidth: .infinity)
    }
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

    if dialog.runModal() == .OK, let result = dialog.url {
      return result
    }
    return nil
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
      if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines)
      {
        return output
      }
    } catch {
      return "Unknown"
    }

    return "Unknown"
  }
}
