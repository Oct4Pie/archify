//
//  ContentView.swift
//  archify
//
//  Created by oct4pie on 6/12/24.
//

import SwiftUI

enum UtilityType: Hashable {
    case appProcessor
    case sizeCalculation
    case langCleaner
    case batchProcessor
}

struct ContentView: View {
    @State private var selectedUtility: UtilityType? = .appProcessor

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("General")) {
                    NavigationLink(
                        destination: AppProcessingView(),
                        tag: UtilityType.appProcessor,
                        selection: $selectedUtility
                    ) {
                        Label("App Processor", systemImage: "gear")
                            .font(.title3)
                            .padding(.vertical, 8)
                    }
                    NavigationLink(
                        destination: SizeCalculationView(),
                        tag: UtilityType.sizeCalculation,
                        selection: $selectedUtility
                    ) {
                        Label("Size Calculation", systemImage: "chart.bar")
                            .font(.title3)
                            .padding(.vertical, 8)
                    }
                }
                
                Section(header: Text("Advanced")) {
                    NavigationLink(
                        destination: LanguageCleanerView(),
                        tag: UtilityType.langCleaner,
                        selection: $selectedUtility
                    ) {
                        Label("Language Cleaner", systemImage: "globe")
                            .font(.title3)
                            .padding(.vertical, 8)
                    }
                    NavigationLink(
                        destination: BatchProcessingView(),
                        tag: UtilityType.batchProcessor,
                        selection: $selectedUtility
                    ) {
                        Label("Batch Processor", systemImage: "globe")
                            .font(.title3)
                            .padding(.vertical, 8)
                    }
                }
            }
            .listStyle(SidebarListStyle())
            .navigationTitle("Utilities")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(action: toggleSidebar) {
                        Image(systemName: "sidebar.left")
                    }
                }
            }
            AppProcessingView()
        }
        .frame(minWidth: 700, minHeight: 650)
        .background(Color(NSColor.windowBackgroundColor))
        .accentColor(.blue)
    }

    private func toggleSidebar() {
        NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
