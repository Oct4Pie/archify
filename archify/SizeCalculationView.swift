//
//  SizeCalculationView.swift
//  archify
//
//  Created by oct4pie on 6/12/24.
//

import SwiftUI

struct SizeCalculationView: View {
    @EnvironmentObject var sizeCalculation: SizeCalculation

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Unneeded Binaries")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.top, 20)
                .padding(.leading, 20)

            Text("Calculate how much unnecessary binaries your installed universal apps have")
                .font(.title3)
                .padding(.leading, 20)

            Text("Your architecture is \(sizeCalculation.systemArch)")
                .font(.callout)
                .padding(.leading, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Select Applications:")
                            .font(.headline)
                            .padding(.leading, 20)

                        Button(action: {
                            if let urls = sizeCalculation.openPanel(
                                canChooseFiles: true, canChooseDirectories: true, allowsMultipleSelection: true)
                            {
                                sizeCalculation.selectedAppPaths = urls.map { $0.path }
                            }
                        }) {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .font(.title2)
                                Text("Browse")
                                    .fontWeight(.semibold)
                            }
                            .padding()
                            .foregroundColor(.white)
                            .background(Color.blue)
                            .cornerRadius(8)
                            .padding(.horizontal, -10)
                            .padding(.vertical, -1)
                        }
                        .padding(.horizontal, 25)
                        .disabled(sizeCalculation.isCalculating) // Disable button when calculating
                    }

                    if !sizeCalculation.selectedAppPaths.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Selected Applications:")
                                .font(.headline)
                                .padding(.leading, 20)
                            List(sizeCalculation.selectedAppPaths, id: \.self) { path in
                                Text(path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .listStyle(PlainListStyle())
                            .frame(minHeight: 200)
                            .padding(.horizontal, 20)
                        }
                    } else {
                        VStack {
                            Text("No applications selected")
                                .foregroundColor(.secondary)
                                .padding(.vertical, 50)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Number of Threads:")
                            .font(.headline)
                            .padding(.leading, 20)

                        Slider(value: Binding(
                            get: { Double(self.sizeCalculation.maxConcurrentProcesses) },
                            set: { self.sizeCalculation.maxConcurrentProcesses = Int($0) }
                        ), in: 1...16, step: 1)
                        .padding(.horizontal, 20)

                        Text("Threads: \(sizeCalculation.maxConcurrentProcesses)")
                            .padding(.leading, 20)
                    }

                    Button(action: {
                        sizeCalculation.calculateUnneededArchSizes()
                    }) {
                        HStack {
                            Image(systemName: "chart.bar.xaxis")
                                .font(.title2)
                            Text("Calculate")
                                .fontWeight(.semibold)
                        }
                        .padding()
                        .foregroundColor(.white)
                        .background(Color.green)
                        .cornerRadius(8)
                        .padding(.vertical, -1)
                        .padding(.horizontal, -10)
                    }
                    .padding(.horizontal, 25)
                    .padding(.vertical, 25)
                    .disabled(sizeCalculation.isCalculating) // Disable button when calculating

                    if sizeCalculation.isCalculating {
                        VStack {
                            ProgressView(value: sizeCalculation.progress, total: 1.0)
                                .padding(.horizontal, 20)
                            Text("Processing \(sizeCalculation.currentApp)")
                                .foregroundColor(.secondary)
                                .padding(.top, 5)
                                .padding(.bottom, 20)
                        }
                    }

                    if sizeCalculation.showCalculationResult {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Results:")
                                .font(.headline)
                                .padding(.leading, 20)
                                .padding(.top, -10)
                            List(sizeCalculation.unneededArchSizes, id: \.0) { app in
                                HStack {
                                    Text(app.0)
                                    Spacer()
                                    Text(sizeCalculation.humanReadableSize(app.1))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .listStyle(PlainListStyle())
                            .frame(minHeight: 200)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 25)
                        }
                    }
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SizeCalculationView_Previews: PreviewProvider {
    static var previews: some View {
        SizeCalculationView()
    }
}
