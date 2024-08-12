//
//  ContentView.swift
//  archify
//
//  Created by oct4pie on 6/12/24.
//

import SwiftUI

enum UtilityType: String, CaseIterable {
    case appProcessor = "App Processor"
    case sizeCalculation = "Size Calculation"
    case langCleaner = "Language Cleaner"
    case batchProcessor = "Batch Processor"
    case universalApps = "Universal Apps"

    var icon: String {
        switch self {
        case .appProcessor: return "gearshape.fill"
        case .sizeCalculation: return "chart.bar.fill"
        case .langCleaner: return "globe"
        case .batchProcessor: return "square.stack.3d.up.fill"
        case .universalApps: return "apps.iphone"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedUtility: UtilityType? = .appProcessor
    @State private var isHovering: UtilityType?
    @State private var showSidebar: Bool = true

    var body: some View {
        NavigationView {
            if showSidebar {
                sidebar
            }
            
            mainContent
        }
        .navigationViewStyle(DoubleColumnNavigationViewStyle())
    }

    var sidebar: some View {
        List {
            ForEach(UtilityType.allCases, id: \.self) { utility in
                NavigationLink(
                    destination: destinationView(for: utility),
                    tag: utility,
                    selection: $selectedUtility
                ) {
                    HStack {
                        Image(systemName: utility.icon)
                            .foregroundColor(.blue)
                            .imageScale(.large)
                        Text(utility.rawValue)
                            .font(.headline)
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(PlainButtonStyle())
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovering == utility ? Color.blue.opacity(0.1) : Color.clear)
                )
                .onHover { hovering in
                    isHovering = hovering ? utility : nil
                }
            }
        }
        .listStyle(SidebarListStyle())
        .frame(minWidth: 200)
    }

    var mainContent: some View {
        Group {
            if let selectedUtility = selectedUtility {
                destinationView(for: selectedUtility)
            } else {
                welcomeView
            }
        }
    }

    var welcomeView: some View {
        VStack(spacing: 20) {
            Image(systemName: "apps.iphone")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 100, height: 100)
                .foregroundColor(.blue)
            Text("Welcome to Archify")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("Select a utility from the sidebar to get started")
                .font(.title3)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    func destinationView(for utility: UtilityType) -> some View {
        switch utility {
        case .appProcessor:
            AppProcessingView()
        case .sizeCalculation:
            SizeCalculationView()
        case .langCleaner:
            LanguageCleanerView()
        case .batchProcessor:
            BatchProcessingView()
        case .universalApps:
            UniversalAppsView()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AppState())
    }
}
