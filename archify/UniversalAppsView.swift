import SwiftUI

struct UniversalAppsView: View {
    @State private var apps: [(name: String, path: String, type: String, architectures: String, icon: NSImage?)] = []
    @State private var isLoading: Bool = true

    var body: some View {
        VStack {
            if isLoading {
                ProgressView("Loading Applications...")
                    .progressViewStyle(CircularProgressViewStyle())
                    .font(.title2)
                    .padding()
            } else {
                Text("Applications")
                    .font(.title2)
                    .bold()
                    .padding(.top, 20)

                List(apps, id: \.path) { app in
                    HStack {
                        if let icon = app.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 40, height: 40)
                                .cornerRadius(5)
                                .padding(.trailing, 10)
                        } else {
                            Image(systemName: "app.fill")
                                .resizable()
                                .frame(width: 40, height: 40)
                                .foregroundColor(.blue)
                                .padding(.trailing, 10)
                        }

                        VStack(alignment: .leading) {
                            Text(app.name)
                                .font(.headline)
                            Text(app.architectures)
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Text(app.type)
                            .font(.subheadline)
                            .bold()
                            .foregroundColor(app.type == "Universal" ? .green : .blue)
                    }
                    .padding(.vertical, 5)
                }
                .listStyle(DefaultListStyle()) // Use DefaultListStyle
            }
        }
        .padding(.horizontal)
        .onAppear(perform: loadApps)
    }

    private func loadApps() {
        UniversalApps.shared.findApps() { apps in
            self.apps = apps
            self.isLoading = false
        }
    }
}

struct UniversalAppsView_Previews: PreviewProvider {
    static var previews: some View {
        UniversalAppsView()
    }
}
