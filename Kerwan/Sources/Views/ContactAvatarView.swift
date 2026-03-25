import SwiftUI

// MARK: - ContactAvatarView

/// A circular avatar for a contact, showing initials or a placeholder icon.
struct ContactAvatarView: View {
    let contact: Contact
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(avatarColor)
                .frame(width: size, height: size)
            Text(initials)
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .accessibilityLabel(contact.displayName)
    }

    private var initials: String {
        let words = contact.displayName
            .split(separator: " ")
            .prefix(2)
        return words.compactMap { $0.first.map { String($0) } }.joined()
    }

    private var avatarColor: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green]
        let hash = abs(contact.displayName.hashValue)
        return palette[hash % palette.count]
    }
}
