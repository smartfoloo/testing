import SwiftUI

enum HomeTab: Hashable {
    case requirements
    case group
    case organizer
}

struct TabPillBar: View {
    @Binding var selection: HomeTab
    let showsOrganizer: Bool

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            tab(.requirements, title: AppCopy.homeRequirements, icon: "checklist")
            tab(.group, title: AppCopy.homeGroup, icon: "person.2")
            if showsOrganizer {
                tab(.organizer, title: AppCopy.homeOrganizer, icon: "slider.horizontal.3")
            }
        }
        .padding(6)
        .background(AppColors.card)
        .clipShape(Capsule())
        .shadow(color: AppColors.ink.opacity(0.08), radius: 10, y: 3)
        .padding(.horizontal, AppSpacing.lg)
    }

    private func tab(_ tab: HomeTab, title: String, icon: String) -> some View {
        Button {
            selection = tab
        } label: {
            Label(title, systemImage: icon)
                .font(AppTypography.caption.weight(.semibold))
                .foregroundStyle(selection == tab ? Color.white : AppColors.ink)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .background(selection == tab ? AppColors.accent : Color.clear)
                .clipShape(Capsule())
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier("tab-\(tab == .requirements ? "requirements" : tab == .group ? "group" : "organizer")")
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
    }
}
