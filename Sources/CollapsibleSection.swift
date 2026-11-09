import SwiftUI

/// A stable native disclosure control. Collapsing hides views, never stops models.
struct CollapsibleSection<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    let content: Content
    @State private var expanded: Bool
    init(_ title: String, key: String, subtitle: String = "", symbol: String = "", initiallyExpanded: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.content = content()
        _expanded = State(initialValue: initiallyExpanded)
    }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            content.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
        } label: {
            HStack(spacing: 10) {
                if !symbol.isEmpty { Image(systemName: symbol).accessibilityHidden(true) }
                Text(title).font(.headline)
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail) }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, minHeight: 24, alignment: .leading).contentShape(Rectangle())
        }.tint(Color.primary).padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.98)).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.18)))
            .transaction { $0.animation = nil }
    }
}
