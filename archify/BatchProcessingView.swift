//
//  BatchProcessingView.swift
//  archify
//
//  Created by oct4pie on 6/20/24.
//

import SwiftUI

struct BatchProcessingView: View {
    @EnvironmentObject var batchProcessing: BatchProcessing
    @State private var showAlert = false

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
                .edgesIgnoringSafeArea(.all)
            
            ScrollView {
                VStack(alignment: .center, spacing: 20) {
                    Text("Batch Process")
                        .font(.title)
                        .fontWeight(.bold)
                        .padding(.bottom, 1)
                    
                    Text("Optimize your applications by removing unnecessary architectures and saving disk space.")
                        .font(.body)
                        .foregroundColor(.gray)
                        .padding(.bottom, 20)

                    if batchProcessing.appSizes.isEmpty && !batchProcessing.isProcessing {
                        VStack {
                            Image(systemName: "tray.full")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 100, height: 100)
                                .foregroundColor(.blue)
                                .padding(.bottom, 20)
                            
                            Text("No applications scanned yet.")
                                .font(.title2)
                                .foregroundColor(.gray)
                                .padding(.bottom, 20)
                        }
                    }
                    
                    if batchProcessing.isProcessing {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Scanning \(batchProcessing.currentApp)...")
                                .font(.subheadline)
                                .foregroundColor(.gray)

                            ProgressView(value: batchProcessing.progress, total: 1.0)
                                .progressViewStyle(LinearProgressViewStyle())
                        }
                        .padding(.bottom, 20)
                    }


                    Button(action: batchProcessing.startCalculatingSizes) {
                        Label("Scan /Applications", systemImage: "chart.bar.doc.horizontal")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(15)
                            .background(batchProcessing.isProcessing ? Color.gray : Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .padding(.horizontal, -10)
                            .padding(.vertical, -1)
                    }.padding(.horizontal, 20)
                    .disabled(batchProcessing.isProcessing)
                    .padding(.bottom, 20)

                    
                    if !batchProcessing.appSizes.isEmpty {
                        Text("Universal Apps:")
                            .font(.title2)
                            .padding(.bottom, 5)

                        List {
                            ForEach(batchProcessing.appSizes, id: \.0) { app, size in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(URL(fileURLWithPath: app).lastPathComponent)
                                            .font(.headline)
                                        Text(app)
                                            .font(.subheadline)
                                            .foregroundColor(.gray)
                                        Text("Unneeded: \(size.humanReadableSize())")
                                            .font(.subheadline)
                                            .foregroundColor(.gray)
                                    }
                                    Spacer()
                                    if batchProcessing.selectedApps.contains(app) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.blue)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if batchProcessing.selectedApps.contains(app) {
                                        batchProcessing.selectedApps.remove(app)
                                    } else {
                                        batchProcessing.selectedApps.insert(app)
                                    }
                                }
                            }
                        }
                        .frame(minHeight: 300, maxHeight: 400)
                        
                        HStack {
                            Button(action: batchProcessing.selectAllApps) {
                                Label("Select All", systemImage: "checkmark.circle.fill")
                                    .font(.headline)
                                    .padding(10)
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(10)
                                    .padding(.horizontal, -10)
                                    .padding(.vertical, -1)
                            }
                            Button(action: batchProcessing.deselectAllApps) {
                                Label("Deselect All", systemImage: "xmark.circle.fill")
                                    .font(.headline)
                                    .padding(10)
                                    .background(Color.red)
                                    .foregroundColor(.white)
                                    .cornerRadius(10)
                                    .padding(.horizontal, -10)
                                    .padding(.vertical, -1)
                            }
                        }
                        .padding(.bottom, 5)

                        Button(action: batchProcessing.startProcessingSelectedApps) {
                            Label("Process Apps", systemImage: "arrow.right.circle.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(15)
                                .background(batchProcessing.selectedApps.isEmpty ? Color.gray : Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                                .padding(.horizontal, -10)
                                .padding(.vertical, -1)
                        }.padding(.horizontal, 15)
                        .disabled(batchProcessing.selectedApps.isEmpty || batchProcessing.isProcessing)
                        .padding(.top, 20)

                        if !batchProcessing.logMessages.isEmpty {
                            Text("Log Messages:")
                                .font(.title2)
                                .padding(.top, 20)
                            ScrollView {
                                Text(batchProcessing.logMessages)
                                    .padding()
                                    .background(Color.gray.opacity(0.1))
                                    .cornerRadius(10)
                            }
                            .frame(height: 200)
                        }

                        if batchProcessing.totalSavedSpace > 0 {
                            Text("Saved: \(batchProcessing.totalSavedSpace.humanReadableSize())")
                                .font(.headline)
                                .padding(.top, 10)
                        }
                    }

                    Spacer()
                }
                .padding()
            }
        }
    }
}

struct BatchProcessingView_Previews: PreviewProvider {
    static var previews: some View {
        BatchProcessingView()
    }
}
