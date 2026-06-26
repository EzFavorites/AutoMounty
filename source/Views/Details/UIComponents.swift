import SwiftUI
import AutoMountyModel

struct Metrics {
    // Only keeping metrics used by other views
    static let accessoryWidth: CGFloat = 24
}

// MARK: - Modern Layout Components

/// Based on Grid form container, automatically aligns labels
/// Requires macOS 13+ (Ventura)
struct FormGrid<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
            content
            
            // Phantom row to force the second column (inputs) to expand to full width
            GridRow {
                Color.clear
                    .frame(width: 0, height: 0)
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true) // Allow grid to fit width naturally
    }
}

/// A row in the Grid
struct GridInputField<Content: View, Actions: View>: View {
    let label: LocalizedStringKey
    let content: Content
    let actions: Actions
    let helpText: LocalizedStringKey?
    
    init(_ label: LocalizedStringKey, help: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.label = label
        self.helpText = help
        self.content = content()
        self.actions = actions()
    }
    
    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .gridColumnAlignment(.trailing)
            
            HStack(spacing: 8) {
                content
                    .frame(maxWidth: .infinity) // Input takes available space
                
                // Fixed reserved space for actions (approx 2 buttons width ~ 50-60pt)
                HStack(spacing: 4) {
                    actions
                }
                .frame(width: 60, alignment: .trailing)
            }
            .gridColumnAlignment(.leading)
        }
        .help(helpText ?? "")
    }
}

extension GridInputField where Actions == EmptyView {
    init(_ label: LocalizedStringKey, help: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.init(label, help: help, content: content, actions: { EmptyView() })
    }
}

// MARK: - Modern Toast / Popup Component

struct Toast: Equatable {
    enum Style {
        case success
        case error
        case info

        var icon: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .error: return "exclamationmark.triangle.fill"
            case .info: return "info.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .success: return .green
            case .error: return .red
            case .info: return .blue
            }
        }
    }

    let id = UUID()
    let style: Style
    let message: String
    let duration: TimeInterval

    init(style: Style, message: String, duration: TimeInterval = 2.0) {
        self.style = style
        self.message = message
        self.duration = duration
    }

    static func == (lhs: Toast, rhs: Toast) -> Bool {
        lhs.id == rhs.id
    }
}

struct ToastView: View {
    let toast: Toast
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.style.icon)
                .font(.title3)
                .foregroundStyle(toast.style.color)
            
            Text(toast.message)
                .font(.body)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
    }
}

struct ToastModifier: ViewModifier {
    @Binding var toast: Toast?
    @State private var workItem: DispatchWorkItem?
    
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                ZStack {
                    if let toast = toast {
                        VStack {
                            Spacer()
                            ToastView(toast: toast)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                                .padding(.bottom, 32)
                        }
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.7), value: toast)
            )
            .onChange(of: toast) { _, newToast in
                if let newToast = newToast {
                    workItem?.cancel()
                    
                    let task = DispatchWorkItem {
                        withAnimation {
                            self.toast = nil
                        }
                    }
                    workItem = task
                    DispatchQueue.main.asyncAfter(deadline: .now() + newToast.duration, execute: task)
                }
            }
    }
}

extension View {
    func toast(_ toast: Binding<Toast?>) -> some View {
        self.modifier(ToastModifier(toast: toast))
    }
}
