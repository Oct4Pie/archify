//
//  FullDiskAccessManager.swift
//  archify
//
//  Created by oct4pie on 11/22/24.
//

import SwiftUI

struct Constants {
    struct Layout {
        static let maxImageWidth: CGFloat = 600
        static let maxImageHeight: CGFloat = 600
        static let contentSpacing: CGFloat = 24
        static let buttonSpacing: CGFloat = 16
        static let cornerRadius: CGFloat = 12
        static let shadowRadius: CGFloat = 3
        static let minWidth: CGFloat = 400
    }
    
    struct AnimationN {
        static let standard = Animation.easeInOut(duration: 0.3)
    }
}

struct Theme {
    static func backgroundColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(white: 0.15) : .white
    }
    
    static func primaryButtonStyle(for colorScheme: ColorScheme) -> some ViewModifier {
        struct ButtonModifier: ViewModifier {
            let colorScheme: ColorScheme
            
            func body(content: Content) -> some View {
                content
                    .background(colorScheme == .dark ? Color.blue : Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
            }
        }
        return ButtonModifier(colorScheme: colorScheme)
    }
}

class FullDiskAccessManager: ObservableObject {
    static let shared = FullDiskAccessManager()
    @Published var showingPermissionAlert = false
    @Published var hasCheckedPermission = false
    
    func requestFullDiskAccess() {
        FullDiskAccessManager.shared.showingPermissionAlert = true
    }
    
    func closeAlert() {
        DispatchQueue.main.async {
            withAnimation(Constants.AnimationN.standard) {
                FullDiskAccessManager.shared.showingPermissionAlert = false
            }
        }
    }
    
    func openSecurityPreferences() {
        print("showingPermissionAlert: \(self.showingPermissionAlert)")
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let urlString = version.majorVersion >= 13
        ? "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        : "x-apple.systempreferences:com.apple.preference.security?Privacy"
        
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}

struct FullDiskAccessAlert: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss
    
    let instructions: String
    let onOpenSettings: () -> Void
    let onLater: () -> Void
    
    var body: some View {
        VStack(spacing: Constants.Layout.contentSpacing) {
            headerView
            instructionsView
            instructionalImage
            buttonStack
        }
        .padding(24)
        .frame(minWidth: Constants.Layout.minWidth)
        .background(Theme.backgroundColor(for: colorScheme))
        .cornerRadius(Constants.Layout.cornerRadius)
        .shadow(radius: Constants.Layout.shadowRadius)
    }
    
    private var headerView: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundColor(.accentColor)
            
            Text("Full Disk Access Required")
                .font(.system(size: 24, weight: .bold))
        }
    }
    
    private var instructionsView: some View {
        Text(instructions)
            .font(.body)
            .multilineTextAlignment(.leading)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var instructionalImage: some View {
        Image(getInstructionalImageName())
            .resizable()
            .scaledToFit()
            .frame(maxWidth: Constants.Layout.maxImageWidth,
                   maxHeight: Constants.Layout.maxImageHeight)
            .cornerRadius(Constants.Layout.cornerRadius)
            .shadow(color: .black.opacity(0.15),
                    radius: Constants.Layout.shadowRadius)
            .overlay(
                RoundedRectangle(cornerRadius: Constants.Layout.cornerRadius)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
    }
    
    private var buttonStack: some View {
        HStack(spacing: Constants.Layout.buttonSpacing) {
            Button("Open Security & Privacy") {
                onOpenSettings()
            }
            .modifier(Theme.primaryButtonStyle(for: colorScheme))
            .keyboardShortcut(.defaultAction)
            
            Button("Ok") {
                withAnimation(Constants.AnimationN.standard) {
                    dismiss()
                }
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.top, 8)
    }
    
    private func getInstructionalImageName() -> String {
        return "fullDiskAccess"
        
    }
}

struct VersionInstructions {
    static func get() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        
        let baseInstructions = """
        To grant access:
        1. %@
        2. %@
        3. %@
        4. %@
        %@
        
        After granting access, please restart the application.
        """
        
        let steps: [String]
        if version.majorVersion >= 13 {
            steps = [
                "Click \"Open Security & Privacy\"",
                "Click the lock icon 🔒 to make changes",
                "Find this app under \"Full Disk Access\"",
                "Toggle the switch to enable access",
                ""
            ]
        } else if version.majorVersion >= 11 {
            steps = [
                "Click \"Open Security & Privacy\"",
                "Select the \"Privacy\" tab",
                "Click the lock icon 🔒 to make changes",
                "Select \"Full Disk Access\" from the left sidebar",
                "\n5. Click the "+" button and add this application"
            ]
        } else {
            steps = [
                "Open System Preferences",
                "Go to Security & Privacy > Privacy",
                "Click the lock icon 🔒 to make changes",
                "Select \"Full Disk Access\" from the left sidebar",
                "\n5. Click the "+" button and add this application"
            ]
        }
        
        return String(format: baseInstructions, arguments: steps)
    }
}

struct FullDiskAccessAlert_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            FullDiskAccessAlert(
                instructions: VersionInstructions.get(),
                onOpenSettings: {},
                onLater: {}
            )
            .preferredColorScheme(.light)
            
            FullDiskAccessAlert(
                instructions: VersionInstructions.get(),
                onOpenSettings: {},
                onLater: {}
            )
            .preferredColorScheme(.dark)
        }
        .padding()
    }
}
