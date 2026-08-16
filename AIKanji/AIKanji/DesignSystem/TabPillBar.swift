import SwiftUI

enum HomeTab: Hashable {
    case requirements
    case status
    case candidates
}

struct TabPillBar: View {
    @Binding var selection: HomeTab
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: AppSpacing.xs) { tabs }
            } else {
                HStack(spacing: AppSpacing.xs) { tabs }
            }
        }
        .padding(6)
        .background(AppColors.card)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .shadow(color: AppColors.ink.opacity(0.08), radius: 10, y: 3)
        .padding(.horizontal, AppSpacing.lg)
    }

    @ViewBuilder
    private var tabs: some View {
        tab(.requirements, title: AppCopy.tabRequirements, icon: "checklist")
        tab(.status, title: AppCopy.tabStatus, icon: "person.2")
        tab(.candidates, title: AppCopy.tabCandidates, icon: "fork.knife")
    }

    private func tab(_ tab: HomeTab, title: String, icon: String) -> some View {
        Button {
            selection = tab
        } label: {
            Label(title, systemImage: icon)
                .font(AppTypography.caption.weight(.semibold))
                .foregroundStyle(selection == tab ? AppColors.accentForeground : AppColors.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .background(selection == tab ? AppColors.accent : Color.clear)
                .clipShape(Capsule())
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier("tab-\(identifier(for: tab))")
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
    }

    private func identifier(for tab: HomeTab) -> String {
        switch tab {
        case .requirements: return "requirements"
        case .status: return "status"
        case .candidates: return "candidates"
        }
    }
}
