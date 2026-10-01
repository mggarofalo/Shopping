import SwiftUI

/// Member identity and role presentation are separate from membership commands.
struct HomeMemberRow<Actions: View>: View {
    let member: HomeMember
    var hasActions = false
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        let presentation = HomeMemberPresentation(member: member)
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .accessibilityIdentifier("shopping.home.member.\(member.id)")
                if let detail = presentation.detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if hasActions {
                Menu(content: actions) {
                    Image(systemName: "ellipsis")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Actions for \(presentation.title)")
                .accessibilityIdentifier("shopping.home.memberActions.\(member.id)")
            }
        }
        .accessibilityElement(children: .contain)
    }
}

#Preview {
    List {
        HomeMemberRow(member: HomeMember(id: "owner", name: nil, role: .owner,
            acceptance: .accepted, isCurrentUser: true, canResend: false)) {
            EmptyView()
        }
    }
}
