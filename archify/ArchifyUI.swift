import SwiftUI

enum ArchifyUI {
    static let contentWidth: CGFloat = 920
    static let pagePadding: CGFloat = 28
    static let sectionSpacing: CGFloat = 18
    static let cardRadius: CGFloat = 12
}

struct ArchifyPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ArchifyUI.sectionSpacing) {
                content()
            }
            .frame(maxWidth: ArchifyUI.contentWidth, alignment: .leading)
            .padding(ArchifyUI.pagePadding)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ArchifyPageHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.bottom, 2)
    }
}

struct ArchifyCard<Content: View>: View {
    let title: String?
    let subtitle: String?
    let systemImage: String?
    @ViewBuilder let content: () -> Content

    init(
        title: String? = nil,
        subtitle: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if title != nil || subtitle != nil {
                HStack(alignment: .top, spacing: 10) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                            .padding(.top, 1)
                            .accessibilityHidden(true)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        if let title {
                            Text(title)
                                .font(.headline)
                        }
                        if let subtitle {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            content()
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: ArchifyUI.cardRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ArchifyUI.cardRadius, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        )
    }
}

enum ArchifyNoticeKind {
    case info
    case success
    case warning
    case destructive

    var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .destructive: return "exclamationmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .info: return .accentColor
        case .success: return .green
        case .warning: return .orange
        case .destructive: return .red
        }
    }
}

struct ArchifyNotice: View {
    let title: String
    let message: String
    var kind: ArchifyNoticeKind = .info

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.icon)
                .foregroundStyle(kind.color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(kind.color.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(kind.color.opacity(0.18), lineWidth: 1)
        )
    }
}

struct ArchifyEmptyState: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

struct ArchifyProgressCard: View {
    let title: String
    let detail: String
    var progress: Double?
    /// Observed so the card redraws when the work is paused or canceled.
    @ObservedObject private var observedControl: RunControl
    private let showsControls: Bool

    /// - Parameter control: When set, shows Pause/Resume and Cancel.
    init(
        title: String,
        detail: String,
        progress: Double? = nil,
        control: RunControl? = nil
    ) {
        self.title = title
        self.detail = detail
        self.progress = progress
        self.observedControl = control ?? RunControl.inactive
        self.showsControls = control != nil
    }

    private var control: RunControl? {
        showsControls ? observedControl : nil
    }

    var body: some View {
        ArchifyCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if control?.state == .paused {
                        Image(systemName: "pause.circle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(stateTitle)
                        .font(.headline)
                    Spacer()
                    if let progress {
                        Text(String(format: "%.0f%%", progress * 100))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    if let control {
                        RunControlButtons(control: control)
                    }
                }

                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                }

                if !stateDetail.isEmpty {
                    Text(stateDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var stateTitle: String {
        switch control?.state {
        case .paused: return "Paused"
        case .stopping: return "Stopping…"
        default: return title
        }
    }

    private var stateDetail: String {
        switch control?.state {
        case .paused:
            return detail.isEmpty
                ? "Resume to continue where it left off."
                : "Paused after: \(detail). Resume to continue where it left off."
        case .stopping:
            return "Finishing the current item so nothing is left half-changed."
        default:
            return detail
        }
    }
}

/// Pause/Resume and Cancel buttons bound to a `RunControl`.
struct RunControlButtons: View {
    @ObservedObject var control: RunControl

    var body: some View {
        HStack(spacing: 6) {
            if control.state == .paused {
                Button {
                    control.resume()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .keyboardShortcut(.space, modifiers: [])
            } else {
                Button {
                    control.pause()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .disabled(control.state != .running)
            }

            Button("Cancel", role: .cancel) {
                control.cancel()
            }
            .disabled(control.state == .stopping || control.state == .idle)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

struct ArchifyStatusPill: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(color.opacity(0.1))
            )
    }
}

struct ArchifyMetric: View {
    let title: String
    let value: String
    var emphasis: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(emphasis ?? .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A disclosure row whose whole label toggles it. On macOS, SwiftUI's
/// `DisclosureGroup` only responds to its small chevron, so clicking the
/// title text appeared to do nothing.
struct ArchifyDisclosure<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content
    @ViewBuilder let label: () -> Label

    init(
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder label: @escaping () -> Label
    ) {
        _isExpanded = isExpanded
        self.content = content
        self.label = label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    label()
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                content()
            }
        }
    }
}

extension ArchifyDisclosure where Label == Text {
    init(
        _ title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(isExpanded: isExpanded, content: content) {
            Text(title)
        }
    }
}

struct ArchifyLogView: View {
    let text: String
    var emptyMessage: String = "Activity will appear here."

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? emptyMessage : text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(minHeight: 110, maxHeight: 210)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        )
    }
}

struct ArchifyLabeledValue: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
    }
}

struct ArchifySearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    Color(nsColor: .separatorColor).opacity(0.6),
                    lineWidth: 1
                )
        )
    }
}

struct ArchifyPathSelector: View {
    let title: String
    let help: String
    let systemImage: String
    @Binding var path: String
    let choose: () -> Void

    private var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.1))
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Text(path.isEmpty ? help : displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !path.isEmpty {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 12)

            Button(path.isEmpty ? "Choose…" : "Change…", action: choose)
                .buttonStyle(.bordered)
        }
    }
}
