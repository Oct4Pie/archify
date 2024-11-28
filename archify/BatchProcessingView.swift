//
//  BatchProcessingView.swift
//  archify
//
//  Created by oct4pie on 6/20/24.
//

import SwiftUI

struct BatchProcessingView: View {
    @EnvironmentObject var batchProcessing: BatchProcessing
    @State private var isHoveringScan = false
    @State private var isHoveringProcess = false
    @State private var showingHelp = false
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .name(ascending: false)
    
    
    
    
    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 30) {
                ScrollView {
                    VStack(spacing: 30) {
                        headerSection
                        if batchProcessing.isScanning {
                            scanningSection
                        } else if batchProcessing.isProcessing {
                            processingSection
                        } else {
                            scanButton
                        }
                        filterSortSection
                        appListSection
                        if !batchProcessing.logMessages.isEmpty {
                            logSection
                        }
                        if batchProcessing.totalSavedSpace > 0 {
                            resultsSection
                        }
                    }
                    .padding()
                }
                
                if !batchProcessing.isScanning && !batchProcessing.isProcessing && !batchProcessing.appSizes.isEmpty {
                    processSelectedButton
                }
            }
        }
        .sheet(isPresented: $batchProcessing.fdaManager.showingPermissionAlert, onDismiss: {
            print("Sheet dismissed")
        }) {
            FullDiskAccessAlert(
                instructions: VersionInstructions.get(),
                onOpenSettings: {
                    batchProcessing.fdaManager.openSecurityPreferences()
                },
                onLater: {
                    batchProcessing.fdaManager.closeAlert()
                }
            ).frame(width: 600, height: 700)
        }
        .popover(isPresented: $showingHelp) {
            HelpView()
        }
    }
    
    var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("Batch Processor")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Optimize multiple applications in one go")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: { showingHelp = true }) {
                Image(systemName: "questionmark.circle")
                    .font(.title2)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding()
        .background(Color(nsColor: NSColor.controlBackgroundColor))
        .cornerRadius(15)
        .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
    }
    
    var scanButton: some View {
        Button(action: batchProcessing.startCalculatingSizes) {
            HStack {
                Image(systemName: "magnifyingglass")
                Text("Scan /Applications")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(10)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(batchProcessing.isProcessing)
        .scaleEffect(isHoveringScan ? 1.01 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isHoveringScan)
        .onHover { hovering in
            isHoveringScan = hovering
        }
        .frame(maxWidth: 200)
    }
    
    var processSelectedButton: some View {
        Button(action: {
            batchProcessing.startProcessingSelectedApps {
                
            }
        }) {
            HStack {
                Image(systemName: "gearshape.2")
                Text("Process Selected")
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(batchProcessing.selectedApps.isEmpty ? Color.gray : Color.blue)
            .foregroundColor(.white)
            .cornerRadius(10)
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isHoveringProcess ? 1.01 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isHoveringProcess)
        .onHover { hovering in
            isHoveringProcess = hovering
        }
        .disabled(batchProcessing.selectedApps.isEmpty)
        .frame(maxWidth: 250)
        .padding(.bottom, 10)
        .padding(.top, -10)
    }
    
    var filterSortSection: some View {
        HStack {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search apps", text: $searchText)
            }
            .padding(8)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(8)
            
            Picker("Sort by", selection: $sortOrder) {
                Text("Name \(sortOrder.isAscending ? "↑" : "↓")").tag(SortOrder.name(ascending: sortOrder.isAscending))
                Text("Size \(sortOrder.isAscending ? "↑" : "↓")").tag(SortOrder.size(ascending: sortOrder.isAscending))
            }
            .pickerStyle(SegmentedPickerStyle())
            .onChange(of: sortOrder) { _ in
                sortOrder.toggle()
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(15)
        .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
    }
    
    var appListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Universal Apps")
                    .font(.headline)
                Spacer()
                Button("Select All") {
                    batchProcessing.selectAllApps()
                }
                .buttonStyle(ModernButtonStyle(color: .blue))
                .disabled(batchProcessing.appSizes.isEmpty)
                Button("Deselect All") {
                    batchProcessing.deselectAllApps()
                }
                .buttonStyle(ModernButtonStyle(color: .red))
                .disabled(batchProcessing.appSizes.isEmpty)
            }
            
            if batchProcessing.appSizes.isEmpty {
                Text("No applications scanned yet.")
                    .foregroundColor(.secondary)
                    .italic()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                List {
                    ForEach(filteredAndSortedApps, id: \.0) { app, totalSize, savableSize in
                        AppRow(app: app, totalSize: totalSize, savableSize: savableSize, isSelected: batchProcessing.selectedApps.contains(app)) {
                            if batchProcessing.selectedApps.contains(app) {
                                batchProcessing.selectedApps.remove(app)
                            } else {
                                batchProcessing.selectedApps.insert(app)
                            }
                        }
                    }
                }
                .listStyle(PlainListStyle())
                .frame(height: 300)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(15)
        .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
    }
    
    var scanningSection: some View {
        VStack(spacing: 15) {
            ProgressView(value: batchProcessing.scanningProgress)
                .progressViewStyle(LinearProgressViewStyle())
            Text("Scanning: \(batchProcessing.currentApp)")
                .font(.caption)
            Text(String(format: "%.0f%%", batchProcessing.scanningProgress * 100))
                .font(.headline)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(15)
        .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
    }
    
    var processingSection: some View {
        VStack(spacing: 15) {
            ProgressView(value: batchProcessing.processingProgress)
                .progressViewStyle(LinearProgressViewStyle())
            Text("Processing: \(batchProcessing.currentApp)")
                .font(.caption)
            Text(String(format: "%.0f%%", batchProcessing.processingProgress * 100))
                .font(.headline)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(15)
        .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
    }
    
    var logSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Log Messages")
                .font(.headline)
            ScrollView {
                Text(batchProcessing.logMessages)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 200)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(15)
        .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
    }
    
    var resultsSection: some View {
        VStack(alignment: .center, spacing: 20) {
            Text("Results")
                .font(.headline)
            
            HStack {
                Text("Total Space Saved:")
                    .font(.title2)
                Text(batchProcessing.totalSavedSpace.humanReadableSize())
                    .font(.title2)
                    .foregroundColor(.green)
            }
            
            PieChartView(
                appSizes: batchProcessing.processedAppSizes
            )
            .frame(height: 300)
            .padding()
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(15)
        .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
    }
    
    var filteredAndSortedApps: [(String, UInt64, UInt64)] {
        let filtered = batchProcessing.appSizes.filter {
            searchText.isEmpty || $0.0.lowercased().contains(searchText.lowercased())
        }
        
        switch sortOrder {
        case .name(let ascending):
            return filtered.sorted { ascending ? $0.0 < $1.0 : $0.0 > $1.0 }
        case .size(let ascending):
            return filtered.sorted { ascending ? $0.2 < $1.2 : $0.2 > $1.2 }
        }
    }
}

struct PieChartView: View {
    let appSizes: [(String, UInt64, UInt64)]  // (app path, total size, savable size)
    
    @State private var selectedSlice: Int? = nil
    
    var body: some View {
        if appSizes.isEmpty {
            Text("No data to display.")
                .foregroundColor(.secondary)
                .italic()
        } else {
            GeometryReader { geometry in
                VStack {
                    ZStack {
                        ForEach(appSizes.indices, id: \.self) { index in
                            PieSliceView(
                                startAngle: startAngle(for: index),
                                endAngle: endAngle(for: index),
                                savableRatio: savableRatio(for: appSizes[index]),
                                isSelected: selectedSlice == index
                            )
                            .onTapGesture {
                                withAnimation {
                                    if selectedSlice == index {
                                        selectedSlice = nil
                                    } else {
                                        selectedSlice = index
                                    }
                                }
                            }
                        }
                        Circle()
                            .fill(Color(NSColor.windowBackgroundColor))
                            .frame(width: geometry.size.width * 0.6, height: geometry.size.width * 0.6)
                        VStack {
                            Text("Total Size")
                                .font(.headline)
                            Text(totalSize.humanReadableSize())
                                .font(.subheadline)
                            Text("Savable")
                                .font(.headline)
                                .padding(.top, 8)
                            Text(totalSavableSize.humanReadableSize())
                                .font(.subheadline)
                            Text(String(format: "%.1f%%", displayablePercentage))
                                .font(.title2)
                                .bold()
                        }
                    }
                    .frame(height: geometry.size.width)
                    .padding()
                    
                    legendView
                    
                    // Debug information
                    Text("Debug: Total Size = \(totalSize), Savable Size = \(totalSavableSize), Percentage = \(savablePercentage)")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(15)
            .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
        }
    }
    
    private var totalSize: UInt64 {
        appSizes.reduce(0) { $0 + $1.1 }
    }
    
    private var totalSavableSize: UInt64 {
        appSizes.reduce(0) { $0 + $1.2 }
    }
    
    private var savablePercentage: Double {
        totalSize == 0 ? 0 : Double(totalSavableSize) / Double(totalSize) * 100
    }
    
    private var displayablePercentage: Double {
        max(savablePercentage, 0.1) // Ensure at least 0.1% is shown
    }
    
    private func startAngle(for index: Int) -> Angle {
        let precedingRatios = appSizes.prefix(index).map { Double($0.1) / Double(totalSize) }
        let radians = precedingRatios.reduce(0, +) * 2 * .pi
        return Angle(radians: radians)
    }
    
    private func endAngle(for index: Int) -> Angle {
        let ratio = Double(appSizes[index].1) / Double(totalSize)
        return startAngle(for: index) + Angle(radians: ratio * 2 * .pi)
    }
    
    private func savableRatio(for appSize: (String, UInt64, UInt64)) -> Double {
        appSize.1 == 0 ? 0 : Double(appSize.2) / Double(appSize.1)
    }
    
    private var legendView: some View {
        VStack(alignment: .leading) {
            ForEach(appSizes.indices, id: \.self) { index in
                HStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.blue.opacity(0.7))
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading) {
                        Text((appSizes[index].0 as NSString).lastPathComponent)
                            .font(.caption)
                        Text("Total: \(appSizes[index].1.humanReadableSize()) / Savable: \(appSizes[index].2.humanReadableSize())")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .opacity(selectedSlice == nil || selectedSlice == index ? 1 : 0.5)
                .onTapGesture {
                    withAnimation {
                        if selectedSlice == index {
                            selectedSlice = nil
                        } else {
                            selectedSlice = index
                        }
                    }
                }
            }
        }
        .padding()
    }
}

struct PieSliceView: View {
    var startAngle: Angle
    var endAngle: Angle
    var savableRatio: Double
    var isSelected: Bool
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Path { path in
                    let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    let radius = min(geometry.size.width, geometry.size.height) / 2
                    path.move(to: center)
                    path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
                    path.closeSubpath()
                }
                .fill(Color.blue.opacity(0.3))
                
                Path { path in
                    let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    let radius = min(geometry.size.width, geometry.size.height) / 2
                    let savableEndAngle = startAngle + Angle(radians: (endAngle.radians - startAngle.radians) * savableRatio)
                    path.move(to: center)
                    path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: savableEndAngle, clockwise: false)
                    path.closeSubpath()
                }
                .fill(Color.blue)
            }
            .scaleEffect(isSelected ? 1.05 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isSelected)
        }
    }
}

struct ModernButtonStyle: ButtonStyle {
    var color: Color
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color)
            .foregroundColor(.white)
            .cornerRadius(8)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

enum SortOrder: Hashable {
    case name(ascending: Bool)
    case size(ascending: Bool)
    
    var isAscending: Bool {
        switch self {
        case .name(let ascending), .size(let ascending):
            return ascending
        }
    }
    
    mutating func toggle() {
        switch self {
        case .name(let ascending):
            self = .name(ascending: !ascending)
        case .size(let ascending):
            self = .size(ascending: !ascending)
        }
    }
}

struct AppRow: View {
    let app: String
    let totalSize: UInt64
    let savableSize: UInt64
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false
    
    var body: some View {
        HStack {
            Button(action: action) {
                HStack {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .foregroundColor(isSelected ? .blue : .secondary)
                    VStack(alignment: .leading) {
                        Text((app as NSString).lastPathComponent)
                            .font(.headline)
                        Text(app)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("Total: \(totalSize.humanReadableSize())")
                            .font(.subheadline)
                        Text("Savable: \(savableSize.humanReadableSize())")
                            .font(.subheadline)
                            .foregroundColor(.blue)
                    }
                }
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.vertical, 5)
        .background(isHovering ? Color.blue.opacity(0.1) : Color.clear)
        .cornerRadius(8)
        .animation(.easeInOut(duration: 0.2), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

struct HelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Batch Processor Help")
                .font(.title)
            
            Text("1. Click 'Scan /Applications' to find universal apps.")
            Text("2. Select the apps you want to optimize.")
            Text("3. Click 'Process Selected' to start.")
            Text("4. Wait for the process to complete.")
            Text("5. Check the results to see how much space you've saved.")
            
            Spacer()
        }
        .padding()
        .frame(width: 400, height: 300)
    }
}



struct BatchProcessingView_Previews: PreviewProvider {
    static var previews: some View {
        let batchProcessing = BatchProcessing()
        batchProcessing.appSizes = [
            ("/Applications/Sample.app", 1000000, 200000),
            ("/Applications/Another.app", 2000000, 500000)
        ]
        return BatchProcessingView()
            .environmentObject(batchProcessing)
    }
}
