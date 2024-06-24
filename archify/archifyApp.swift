//
//  archifyApp.swift
//  archify
//
//  Created by m3hdi on 6/12/24.
//

import SwiftUI

@main
struct archifyApp: App {
    @StateObject var appState = AppState()
    @StateObject var languageCleaner = LanguageCleaner()
    @StateObject var batchProcessing = BatchProcessing()
    @StateObject var sizeCalculation = SizeCalculation()
  var body: some Scene {
    WindowGroup {
      ContentView()
            .environmentObject(appState)
            .environmentObject(languageCleaner)
            .environmentObject(batchProcessing)
            .environmentObject(sizeCalculation)
    }
  }
}
