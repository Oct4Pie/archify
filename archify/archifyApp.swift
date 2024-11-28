//
//  archifyApp.swift
//  archify
//
//  Created by Oct4Pie on 6/12/24.
//

import SwiftUI

@main
struct archifyApp: App {
    @StateObject var appState = AppState()
    @StateObject var languageCleaner = LanguageCleaner()
    @StateObject var batchProcessing = BatchProcessing()
    @StateObject var sizeCalculation = SizeCalculation()
    @StateObject var universalAppsView = UniversalAppsViewModel()
    var body: some Scene {
        WindowGroup {
            
            ContentView()
                
                .environmentObject(appState)
                .environmentObject(languageCleaner)
                .environmentObject(batchProcessing)
                .environmentObject(sizeCalculation)
                .environmentObject(universalAppsView)
                
        }
            .windowStyle(HiddenTitleBarWindowStyle())
        
            
        
    }

}
