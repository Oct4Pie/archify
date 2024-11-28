//
//  LanguageCleanerView.swift
//  archify
//
//  Created by oct4pie on 6/20/24.
//

import SwiftUI
import Combine

struct LanguageCleanerView: View {
    @EnvironmentObject var viewModel: LanguageCleaner
    
    var body: some View {
        VStack {
            ScrollView {
                VStack {
                    if viewModel.isScanning {
                        scanningView
                    } else if viewModel.isRemoving {
                        removingView
                    } else {
                        content
                    }
                }
                .padding()
                .frame(minWidth: 600, maxHeight: 750)
                VStack {
                    if viewModel.removedFilesLog != "" {
                        removedFilesLog
                    }
                }.padding()
            }
            
        }.background(Color(NSColor.windowBackgroundColor))
    }
    
    @ViewBuilder
    private var scanningView: some View {
        VStack {
            Spacer()
            VStack {
                ProgressView("Scanning...", value: viewModel.progress, total: 1.0)
                    .progressViewStyle(CircularProgressViewStyle())
                    .padding()
                Text(String(format: "%.0f%%", viewModel.progress * 100))
                    .font(.title2)
                    .bold()
                Text(viewModel.currentlyScanningApp)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.top, 10)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    @ViewBuilder
    private var removingView: some View {
        VStack {
            Spacer()
            VStack {
                ProgressView("Removing...", value: viewModel.progress, total: 1.0)
                    .progressViewStyle(CircularProgressViewStyle())
                    .padding()
                Text(String(format: "%.0f%%", viewModel.progress * 100))
                    .font(.title2)
                    .bold()
                Text(viewModel.currentlyRemovingFile)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.top, 10)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    @ViewBuilder
    private var content: some View {
        HStack(alignment: .top) {
            VStack {
                selectAllButton
                uniqueLanguagesList
                    .frame(minHeight: 500)
            }
            .frame(maxWidth: 200)
            
            VStack {
                searchBar
                appsList
                    .frame(minHeight: 500)
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(NSColor.controlBackgroundColor))
            .shadow(radius: 2))
        controlButtons
            .padding(.top)
    }
    
    @ViewBuilder
    private var selectAllButton: some View {
        Button(action: {
            viewModel.toggleSelectAllLanguages()
        }) {
            Text(viewModel.isAllLanguagesSelected ? "Deselect All Languages" : "Select All Languages")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PlainButtonStyle())
        .background(Color.accentColor)
        .foregroundColor(.white)
        .cornerRadius(8)
        .padding(.vertical, 10)
    }
    
    @ViewBuilder
    private var uniqueLanguagesList: some View {
        List {
            ForEach(viewModel.uniqueLanguages, id: \.self) { language in
                HStack {
                    Text(language)
                        .foregroundColor(viewModel.shouldGrayOutLanguage(language) ? .gray : .primary)
                    Spacer()
                    if viewModel.selectedLanguages.contains(language) {
                        Image(systemName: "checkmark")
                            .foregroundColor(.accentColor)
                    }
                }
                .padding(.horizontal, 5)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !viewModel.shouldGrayOutLanguage(language) {
                        viewModel.toggleGlobalLanguage(language)
                    }
                }
            }
        }
        .listStyle(PlainListStyle())
    }
    
    @ViewBuilder
    private var appsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading) {
                ForEach(viewModel.filteredApps) { app in
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { viewModel.expandedApps[app.id, default: false] },
                            set: { viewModel.expandedApps[app.id] = $0 }
                        )
                    ) {
                        VStack(alignment: .leading) {
                            Button(action: {
                                viewModel.toggleSelectAllLanguages(in: app)
                            }) {
                                HStack {
                                    Text(viewModel.isAllLanguagesSelected(in: app) ? "Deselect All Languages" : "Select All Languages")
                                    Spacer()
                                    if viewModel.isAllLanguagesSelected(in: app) {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                                .padding(.horizontal, 5)
                            }
                            .buttonStyle(PlainButtonStyle())
                            
                            ForEach(app.languages, id: \.self) { language in
                                HStack {
                                    Text(language)
                                        .foregroundColor(viewModel.shouldGrayOutLanguage(language) ? .gray : .primary)
                                    Spacer()
                                    if viewModel.isLanguageSelectedInApp(language, app: app) {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if !viewModel.shouldGrayOutLanguage(language) {
                                        viewModel.toggleLanguageInApp(language, app: app)
                                    }
                                }
                            }
                        }
                    } label: {
                        Text(app.appName)
                            .font(.headline)
                            .padding(.vertical, 5)
                    }
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    @ViewBuilder
    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search Apps", text: $viewModel.searchText)
                .textFieldStyle(PlainTextFieldStyle())
                .padding(8)
                .background(Color(NSColor.tertiaryLabelColor).opacity(0.1))
                .cornerRadius(8)
        }
        .padding(.vertical)
    }
    
    @ViewBuilder
    private var controlButtons: some View {
        HStack(spacing: 10) {
            Button(action: {
                viewModel.scanForAppsAndLanguages()
            }) {
                VStack {
                    Text("Scan")
                }
                .padding(.horizontal, 25)
                .padding(.vertical, 7)
                .background(Color.blue)
                
            }
            .buttonStyle(LinkButtonStyle())
            .foregroundColor(.white)
            .cornerRadius(8)
            
            Button(action: {
                viewModel.removeSelected()
            }) {
                
                
                VStack {
                    Text("Remove Selected")
                        .padding(.vertical, 5)
                        .padding(.horizontal, 25)
                }
                
            }
            .background(viewModel.isRemoveButtonEnabled ? Color.red : Color.gray)
            .foregroundColor(.white)
            
            .disabled(!viewModel.isRemoveButtonEnabled)
            .cornerRadius(8)
        }
        .padding(.horizontal)
    }
    
    @ViewBuilder
    private var removedFilesLog: some View {
        VStack(alignment: .leading) {
            Text("Log:")
                .font(.headline)
            ScrollView {
                Text(viewModel.removedFilesLog)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(maxHeight: 250)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.textBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray, lineWidth: 1)
            )
        }
        .padding(5)
    }
}
