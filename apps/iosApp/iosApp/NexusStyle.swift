import SwiftUI

enum NexusStyle {
    static let background2 = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ?
            UIColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1) :
            UIColor(red: 0.98, green: 0.985, blue: 0.995, alpha: 1)
    })
    static let surface = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ?
            UIColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1) :
            UIColor.white
    })
    static let background = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ?
            UIColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1) :
            UIColor(red: 0.965, green: 0.976, blue: 0.992, alpha: 1)
    })
    static let card = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ?
            UIColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 0.9) :
            UIColor.white.withAlphaComponent(0.86)
    })
    static let row = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ?
            UIColor(red: 0.14, green: 0.15, blue: 0.17, alpha: 1) :
            UIColor(red: 0.975, green: 0.981, blue: 0.992, alpha: 1)
    })
    static let selected = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ?
            UIColor(red: 0.15, green: 0.20, blue: 0.30, alpha: 1) :
            UIColor(red: 0.86, green: 0.902, blue: 0.978, alpha: 1)
    })
    static let line = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ?
            UIColor(red: 0.22, green: 0.23, blue: 0.26, alpha: 1) :
            UIColor(red: 0.87, green: 0.895, blue: 0.94, alpha: 1)
    })
    static let border = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ?
            UIColor(red: 0.28, green: 0.30, blue: 0.35, alpha: 1) :
            UIColor(red: 0.80, green: 0.842, blue: 0.91, alpha: 1)
    })
    static let blue = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ?
            UIColor(red: 0.25, green: 0.55, blue: 1.0, alpha: 1) :
            UIColor(red: 0.03, green: 0.345, blue: 0.94, alpha: 1)
    })
    static let green = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ?
            UIColor(red: 0.25, green: 0.70, blue: 0.45, alpha: 1) :
            UIColor(red: 0.12, green: 0.56, blue: 0.34, alpha: 1)
    })
    static let text = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ?
            UIColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1) :
            UIColor(red: 0.18, green: 0.19, blue: 0.22, alpha: 1)
    })
    static let muted = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ?
            UIColor(red: 0.70, green: 0.72, blue: 0.76, alpha: 1) :
            UIColor(red: 0.47, green: 0.49, blue: 0.54, alpha: 1)
    })
    static let subtleText = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ?
            UIColor(red: 0.55, green: 0.57, blue: 0.62, alpha: 1) :
            UIColor(red: 0.66, green: 0.68, blue: 0.73, alpha: 1)
    })
    static let bubbleBg = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ?
            UIColor(red: 0.14, green: 0.15, blue: 0.17, alpha: 1) :
            UIColor.white
    })
}

struct ToastMessage: Identifiable {
    let id = UUID()
    let text: String
    let kind: Kind

    enum Kind {
        case success, error, info
    }
}

struct ToastView: View {
    let message: ToastMessage

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: message.kind == .success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(message.kind == .success ? NexusStyle.blue : .red)
            Text(message.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(NexusStyle.text)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.12), radius: 16, x: 0, y: 6)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}

extension View {
    func cardStyle() -> some View {
        padding(14)
            .background(NexusStyle.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.035), radius: 16, x: 0, y: 8)
    }

    /// Input field shaped for the flat card style (home/Add-bot/settings).
    func fieldInput() -> some View {
        font(.system(size: 15))
            .foregroundStyle(NexusStyle.text)
            .autocorrectionDisabled()
            .padding(12)
            .background(NexusStyle.row, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(NexusStyle.line, lineWidth: 1))
    }
}
