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
                if viewModel.isScanning {
                    scanningView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.isRemoving {
                    removingView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack {
                        VStack {
                            selectAllButton
                            uniqueLanguagesList
                                .frame(minHeight: 500)
                        }
                        VStack {
                            searchBar
                            appsList
                                .frame(minHeight: 500)
                        }
                    }
                    controlButtons
                }
                if viewModel.removedFilesLog != "" {
                    removedFilesLog
                }
            }
            .padding()
            
        }.frame(minWidth: 600, maxHeight: .infinity)
    }

    @ViewBuilder
    private var scanningView: some View {
        VStack {
            Spacer()
            VStack {
                ProgressView("Scanning...", value: viewModel.progress, total: 1.0)
                    .padding()
                Text(String(format: "%.0f%%", viewModel.progress * 100))
                Text(viewModel.currentlyScanningApp)
                    .font(.subheadline)
                    .foregroundColor(.gray)
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
                    .padding()
                Text(String(format: "%.0f%%", viewModel.progress * 100))
                Text(viewModel.currentlyRemovingFile)
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .padding(.top, 10)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var selectAllButton: some View {
        Button(viewModel.isAllLanguagesSelected ? "Deselect All Languages" : "Select All Languages") {
            viewModel.toggleSelectAllLanguages()
        }
        .padding()
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
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if !viewModel.shouldGrayOutLanguage(language) {
                        viewModel.toggleGlobalLanguage(language)
                    }
                }
            }
        }
        .listStyle(PlainListStyle())
        .frame(minWidth: 200)
    }

    @ViewBuilder
    private var searchBar: some View {
        HStack {
            TextField("Search Apps", text: $viewModel.searchText)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding()
        }
    }

    @ViewBuilder
    private var appsList: some View {
        List {
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
                                }
                            }
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())

                        ForEach(app.languages, id: \.self) { language in
                            HStack {
                                Text(language)
                                    .foregroundColor(viewModel.shouldGrayOutLanguage(language) ? .gray : .primary)
                                Spacer()
                                if viewModel.isLanguageSelectedInApp(language, app: app) {
                                    Image(systemName: "checkmark")
                                }
                            }
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
                }
            }
        }
        .listStyle(SidebarListStyle())
        .frame(minWidth: 400)
    }

    @ViewBuilder
    private var controlButtons: some View {
        HStack {
            Button("Scan") {
                viewModel.scanForAppsAndLanguages()
            }
            .padding()
            
            Button("Remove Selected") {
                viewModel.removeSelected()
            }
            .padding()
            .disabled(!viewModel.isRemoveButtonEnabled)
        }
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
            .border(Color.gray, width: 1)
        }
        .padding(5)
    }
}

