//
//  SizeCalculationView.swift
//  archify
//
//  Created by oct4pie on 6/20/24.
//

import SwiftUI

struct SizeCalculationView: View {
    @EnvironmentObject var sizeCalculation: SizeCalculation
    @State private var isHoveringCalculate = false
    @State private var selectedTab = 0
    @State private var showingInfoPopover = false
    @State private var scrollProxy: ScrollViewProxy?
    
    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).edgesIgnoringSafeArea(.all)
            
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 20) {
                        headerSection
                        
                        TabView(selection: $selectedTab) {
                            appSelectionSection
                                .tabItem {
                                    Label("Select Apps", systemImage: "folder")
                                }
                                .tag(0)
                            
                            configurationSection
                                .tabItem {
                                    Label("Configure", systemImage: "gear")
                                }
                                .tag(1)
                        }
                        .padding()
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(15)
                        .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
                        .frame(minHeight: 500)
                        
                        calculateButton
                        
                        if sizeCalculation.isCalculating {
                            progressSection
                        }
                        
                        if sizeCalculation.showCalculationResult {
                            resultsSection
                                .id("resultsSection")
                                .transition(.opacity)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .onChange(of: sizeCalculation.showCalculationResult) { newValue in
                    if newValue {
                        withAnimation {
                            proxy.scrollTo("resultsSection", anchor: .top)
                        }
                    }
                }
                .onAppear {
                    scrollProxy = proxy
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    var headerSection: some View {
        HStack(spacing: 15) {
            Image(systemName: "archivebox.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 40, height: 40)
                .foregroundColor(.blue)
            
            VStack(alignment: .leading, spacing: 5) {
                Text("Extra Binaries Calculator")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Calculate unnecessary binary sizes in your apps")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: { showingInfoPopover.toggle() }) {
                Image(systemName: "info.circle")
                    .font(.title2)
                    .foregroundColor(.blue)
            }
            .popover(isPresented: $showingInfoPopover) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your architecture: \(sizeCalculation.systemArch)")
                        .font(.headline)
                    Text("This tool helps you identify and calculate the size of unnecessary binary architectures in your applications.")
                        .font(.body)
                }
                .padding()
                .frame(width: 300)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(15)
        .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
    }
    
    var appSelectionSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Select Applications")
                .font(.headline)
            
            Button(action: selectApps) {
                HStack {
                    Image(systemName: "folder")
                    Text("Browse")
                }
                .frame(maxWidth: 200)
                .padding(.vertical, 5)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .buttonStyle(PlainButtonStyle())
            
            if !sizeCalculation.selectedAppPaths.isEmpty {
                Text("Selected Applications:")
                    .font(.subheadline)
                    .padding(.top, 5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(sizeCalculation.selectedAppPaths, id: \.self) { path in
                            HStack {
                                Image(systemName: "app")
                                Text((path as NSString).lastPathComponent)
                                    .font(.system(.body, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button(action: { removeApp(path) }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(.vertical, 5)
                            .padding(.horizontal, 10)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(8)
                        }
                    }
                }
                .frame(maxHeight: 200)
            } else {
                Text("No applications selected")
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.vertical, 10)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(15)
        .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
    }
    
    var configurationSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 15) {
                Text("Calculation Threads")
                    .font(.headline)
                HStack {
                    Slider(value: Binding(
                        get: { Double(self.sizeCalculation.maxConcurrentProcesses) },
                        set: { self.sizeCalculation.maxConcurrentProcesses = Int($0) }
                    ), in: 1...16, step: 1)
                    Text("\(sizeCalculation.maxConcurrentProcesses)")
                        .frame(width: 30)
                        .font(.system(.body, design: .monospaced))
                }
                Text("More threads may speed up the calculation, but will use more system resources.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(15)
            .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
        }.padding()
        
    }
    
    var calculateButton: some View {
        Button(action: {
            sizeCalculation.calculateUnneededArchSizes()
            withAnimation {
                scrollProxy?.scrollTo("resultsSection", anchor: .top)
            }
        }) {
            HStack {
                Image(systemName: "gear")
                Text("Calculate")
            }
            .font(.headline)
            .frame(maxWidth: 200)
            .padding()
            .background(sizeCalculation.isCalculating ? Color.gray : Color.blue)
            .foregroundColor(.white)
            .cornerRadius(10)
            .padding(.horizontal, -11)
            .padding(.vertical, -1)
        }
        .disabled(sizeCalculation.isCalculating || sizeCalculation.selectedAppPaths.isEmpty)
        .scaleEffect(isHoveringCalculate ? 1.01 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6, blendDuration: 0), value: isHoveringCalculate)
        .onHover { hovering in
            isHoveringCalculate = hovering
        }
        .shadow(color: Color.black.opacity(0.2), radius: 5, x: 0, y: 3)
        
    }
    
    var progressSection: some View {
        VStack(spacing: 10) {
            ProgressView(value: sizeCalculation.progress, total: 1.0)
                .progressViewStyle(LinearProgressViewStyle())
            Text("Processing \(sizeCalculation.currentApp)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(15)
        .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
    }
    
    var resultsSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Results")
                .font(.headline)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(sizeCalculation.unneededArchSizes, id: \.0) { app in
                        HStack {
                            VStack(alignment: .leading) {
                                Text((app.0 as NSString).lastPathComponent)
                                    .font(.system(.body, design: .monospaced))
                                    .lineLimit(1)
                                Text(app.0)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(sizeCalculation.humanReadableSize(app.1))
                                .foregroundColor(.blue)
                                .fontWeight(.semibold)
                        }
                        .padding()
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(10)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(15)
        .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
    }
    
    func selectApps() {
        if let urls = sizeCalculation.openPanel(
            canChooseFiles: true, canChooseDirectories: true, allowsMultipleSelection: true)
        {
            sizeCalculation.selectedAppPaths = urls.map { $0.path }
        }
    }
    
    func removeApp(_ app: String) {
        sizeCalculation.selectedAppPaths.removeAll { $0 == app }
    }
}

struct SizeCalculationView_Previews: PreviewProvider {
    static var previews: some View {
        SizeCalculationView()
            .environmentObject(SizeCalculation())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
