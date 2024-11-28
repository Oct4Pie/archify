//
//  UniversalAppsView.swift
//  archify
//
//  Created by oct4pie on 6/20/24.
//

import SwiftUI

struct AppInfo: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let type: String
    let architectures: String
    let icon: NSImage?
}

struct UniversalAppsView: View {
    @EnvironmentObject var viewModel: UniversalAppsViewModel
    @State private var selectedApp: AppInfo? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            headerSection
            if viewModel.isLoading {
                loadingSection
            } else {
                filterAndSortSection
                appListSection
            }
        }
        .background(Color(.windowBackgroundColor).edgesIgnoringSafeArea(.all))
        .sheet(item: $selectedApp) { app in
            AppDetailView(app: app, isPresented: $selectedApp)
        }
        .onAppear {
            viewModel.loadApps()
        }
    }
    
    var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("Universal Apps")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                Text("View your installed applications")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: {
                withAnimation {
                    viewModel.reloadApps()
                }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.title2)
                    .foregroundColor(.white)
                    .frame(width: 50, height: 50)
                    .background(Color.accentColor)
                    .clipShape(Circle())
                    .shadow(color: Color.accentColor.opacity(0.3), radius: 5, x: 0, y: 3)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding()
        .background(Color(.controlBackgroundColor))
    }
    
    var loadingSection: some View {
        VStack {
            ProgressView()
                .scaleEffect(2)
                .padding()
            Text("Loading Applications...")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
    }
    
    var filterAndSortSection: some View {
        VStack(spacing: 15) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search applications", text: $viewModel.searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding(8)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(8)
            }
            .padding(.horizontal)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(UniversalAppsViewModel.AppType.allCases, id: \.self) { type in
                        FilterChip(title: type.rawValue.capitalized, isSelected: viewModel.selectedType == type) {
                            withAnimation {
                                viewModel.selectedType = type
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
            
            HStack {
                Text("Sort by:")
                    .foregroundColor(.secondary)
                Menu {
                    Button("Name (A-Z)") { viewModel.sortOrder = .nameAscending }
                    Button("Name (Z-A)") { viewModel.sortOrder = .nameDescending }
                    Button("Type") { viewModel.sortOrder = .type }
                } label: {
                    HStack {
                        Text(viewModel.sortOrder.description)
                        Image(systemName: "chevron.down")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(8)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
        .background(Color(.controlBackgroundColor))
    }
    
    var appListSection: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(filteredAndSortedApps) { app in
                    AppListRow(app: app)
                        .onTapGesture {
                            selectedApp = app
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                        .background(Color(.controlBackgroundColor))
                        .cornerRadius(12)
                        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
                }
            }
            .padding()
        }
    }
    
    var filteredAndSortedApps: [AppInfo] {
        viewModel.apps.filter { app in
            (viewModel.searchText.isEmpty || app.name.lowercased().contains(viewModel.searchText.lowercased())) &&
            (viewModel.selectedType == .all || app.type.lowercased() == viewModel.selectedType.rawValue.lowercased())
        }
        .sorted { app1, app2 in
            switch viewModel.sortOrder {
            case .nameAscending:
                return app1.name < app2.name
            case .nameDescending:
                return app1.name > app2.name
            case .type:
                return app1.type < app2.type
            }
        }
    }
}

struct AppListRow: View {
    let app: AppInfo
    
    var body: some View {
        HStack(spacing: 15) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 50, height: 50)
                    .cornerRadius(10)
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 50, height: 50)
                    .foregroundColor(.blue)
            }
            
            VStack(alignment: .leading, spacing: 5) {
                Text(app.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(app.type)
                    .font(.caption)
                    .padding(5)
                    .background(backgroundColor(for: app.type))
                    .foregroundColor(.white)
                    .cornerRadius(5)
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
        }
    }
    
    func backgroundColor(for type: String) -> Color {
        switch type.lowercased() {
        case "universal":
            return .green
        case "native":
            return .blue
        default:
            return .gray
        }
    }
}

struct AppDetailView: View {
    let app: AppInfo
    @Binding var isPresented: AppInfo?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Spacer()
                Button(action: {
                    isPresented = nil
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 10)
            
            HStack(spacing: 20) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 100, height: 100)
                        .cornerRadius(20)
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 100, height: 100)
                        .foregroundColor(.blue)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text(app.name)
                        .font(.title)
                        .fontWeight(.bold)
                    Text(app.type)
                        .font(.headline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(backgroundColor(for: app.type))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 15) {
                DetailRow(title: "Path", value: app.path)
                DetailRow(title: "Architectures", value: app.architectures)
            }
            
            Spacer()
        }
        .padding()
        .frame(width: 450, height: 350)
        .background(Color(.windowBackgroundColor))
        .cornerRadius(10)
    }
    
    func backgroundColor(for type: String) -> Color {
        switch type.lowercased() {
        case "universal":
            return .green
        case "native":
            return .blue
        default:
            return .gray
        }
    }
}

struct DetailRow: View {
    let title: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
            Text(value)
                .font(.body)
                .padding(8)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(8)
        }
    }
}

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.1))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(20)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// The UniversalAppsViewModel remains unchanged

class UniversalAppsViewModel: ObservableObject {
    @Published var apps: [AppInfo] = []
    @Published var isLoading: Bool = true
    @Published var searchText: String = ""
    @Published var sortOrder: SortOrder = .nameAscending
    @Published var selectedType: AppType = .all
    private var hasLoaded: Bool = false
    
    func loadApps() {
        guard !hasLoaded else { return }
        isLoading = true
        UniversalApps.shared.findApps { loadedApps in
            DispatchQueue.main.async {
                self.apps = loadedApps.map { AppInfo(name: $0.name, path: $0.path, type: $0.type, architectures: $0.architectures, icon: $0.icon) }
                self.isLoading = false
                self.hasLoaded = true
            }
        }
    }
    
    func reloadApps() {
        isLoading = true
        UniversalApps.shared.findApps { loadedApps in
            DispatchQueue.main.async {
                self.apps = loadedApps.map { AppInfo(name: $0.name, path: $0.path, type: $0.type, architectures: $0.architectures, icon: $0.icon) }
                self.isLoading = false
            }
        }
    }
    
    enum SortOrder: CustomStringConvertible {
        case nameAscending, nameDescending, type
        
        var description: String {
            switch self {
            case .nameAscending:
                return "Name (A-Z)"
            case .nameDescending:
                return "Name (Z-A)"
            case .type:
                return "Type"
            }
        }
    }
    
    enum AppType: String, CaseIterable {
        case all, universal, native, other
    }
}
