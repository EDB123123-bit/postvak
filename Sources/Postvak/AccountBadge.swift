import SwiftUI
import PostvakCore

/// An account's colour with its letter inside, so the inboxes can be told apart without remembering the colours.
struct AccountBadge: View {
    let account: Account?
    var size: CGFloat = 14

    private var color: Color { account.map { Color(hex: $0.colorHex) } ?? .gray }
    private var letter: String { account?.badgeLetter ?? "?" }

    var body: some View {
        Group {
            // Apple's circled letters are drawn centred, which text laid on a circle is not.
            if let c = letter.lowercased().unicodeScalars.first, ("a"..."z").contains(c) || ("0"..."9").contains(c) {
                Image(systemName: "\(letter.lowercased()).circle.fill")
                    .resizable()
                    .fontWeight(.bold)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, color)
            } else {
                ZStack {
                    Circle().fill(color)
                    Text(letter).font(.system(size: size * 0.6, weight: .bold)).foregroundStyle(.white).minimumScaleFactor(0.5)
                }
            }
        }
        .frame(width: size, height: size)
        .help(account?.email ?? "")
        .accessibilityLabel(account?.email ?? "Account")
    }
}

extension AppModel {
    /// The badge for an account id, as shown on mail, events and drafts.
    func badge(_ accountId: String, size: CGFloat = 14) -> AccountBadge { AccountBadge(account: account(accountId), size: size) }
}
