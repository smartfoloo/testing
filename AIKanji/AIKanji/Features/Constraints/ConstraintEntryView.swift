import SwiftUI

private struct PreferenceOptionLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(subviews: subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layout(subviews: subviews, width: bounds.width)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: result.sizes[index].width, height: result.sizes[index].height)
            )
        }
    }

    private func layout(subviews: Subviews, width: CGFloat) -> (points: [CGPoint], sizes: [CGSize], size: CGSize) {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for size in sizes {
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            contentWidth = max(contentWidth, x - spacing)
        }
        return (
            points,
            sizes,
            CGSize(width: width.isFinite ? width : contentWidth, height: sizes.isEmpty ? 0 : y + rowHeight)
        )
    }
}

struct ConstraintEntryView: View {
    let eventId: UUID
    let participantId: UUID
    let preferencesClosed: Bool?
    private let service = ConstraintService()
    @State private var constraints: [ConstraintService.SavedConstraint] = []
    @State private var isEditorPresented = false
    @State private var editingConstraint: ConstraintService.SavedConstraint?
    @State private var pendingDeletion: ConstraintService.SavedConstraint?
    @State private var isLoading = true
    @State private var deletingConstraintID: UUID?
    @State private var errorMessage: String?

    private var preferencesOpen: Bool { preferencesClosed == false }

    var body: some View {
        Group {
            if isEditorPresented {
                ConstraintEditorView(
                    eventId: eventId,
                    participantId: participantId,
                    existing: editingConstraint,
                    preferencesClosed: preferencesClosed,
                    onCancel: closeEditor
                ) { savedConstraint in
                    upsert(savedConstraint)
                    closeEditor()
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppSpacing.xl) {
                        header
                        if isLoading {
                            LoadingStateView(title: "保存した希望を読み込んでいます")
                        } else {
                            savedConstraintsSection
                            if preferencesOpen { addConstraintButton }
                        }
                        if let errorMessage {
                            InlineErrorView(message: errorMessage) { self.errorMessage = nil }
                        }
                    }
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.bottom, AppSpacing.xxl)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .background(AppColors.background)
        .task { await load() }
        .onChange(of: preferencesClosed) { _, closed in
            if closed == true {
                pendingDeletion = nil
                if isEditorPresented { errorMessage = AppCopy.preferencesClosedError }
            }
        }
        .alert(
            "この希望を削除しますか？",
            isPresented: Binding(
                get: { pendingDeletion != nil && preferencesOpen },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { constraint in
            Button("削除", role: .destructive) { Task { await delete(constraint) } }
            Button(AppCopy.cancel, role: .cancel) {}
        } message: { constraint in
            Text("「\(constraint.rawText)」を削除します。この操作は取り消せません。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(AppCopy.homeRequirements).font(AppTypography.title)
            Text("みんなで納得できるお店の条件を教えてください。")
                .font(AppTypography.body)
                .foregroundStyle(AppColors.ink.opacity(0.72))
            if preferencesClosed == true {
                Label(AppCopy.preferencesClosedError, systemImage: "lock.fill")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.ink)
                    .padding(AppSpacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColors.greenSoft)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.field))
                    .accessibilityIdentifier("constraints-closed")
            } else if preferencesClosed == nil {
                ProgressView("受付状況を確認しています")
                    .font(AppTypography.caption)
                    .accessibilityIdentifier("constraints-readiness-loading")
            }
        }
    }

    private var savedConstraintsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("保存した希望").font(AppTypography.section)
            if constraints.isEmpty {
                EmptyStateView(
                    title: "保存した希望はまだありません",
                    message: preferencesOpen
                        ? "「希望を追加」から、外せない条件やできれば叶えたい希望を追加してください。"
                        : "希望の受付は終了しています。"
                )
                .accessibilityIdentifier("constraints-empty-state")
            } else {
                ForEach(constraints) { constraint in constraintRow(constraint) }
            }
        }
        .accessibilityIdentifier("saved-constraints-list")
    }

    private func constraintRow(_ constraint: ConstraintService.SavedConstraint) -> some View {
        AppCard {
            HStack(alignment: .top, spacing: AppSpacing.sm) {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text(constraint.rawText).font(AppTypography.body.weight(.semibold))
                    HStack(spacing: AppSpacing.sm) {
                        Text(constraint.kind.title).font(AppTypography.caption.weight(.bold))
                        Label(constraint.visibility.label, systemImage: visibilityIcon(constraint.visibility))
                            .font(AppTypography.caption)
                    }
                    .foregroundStyle(AppColors.ink.opacity(0.72))
                }
                Spacer(minLength: 0)
                if preferencesOpen { constraintActions(constraint) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("constraint-row-\(constraint.id.uuidString)")
    }

    private func constraintActions(_ constraint: ConstraintService.SavedConstraint) -> some View {
        Menu {
            Button {
                editingConstraint = constraint
                isEditorPresented = true
            } label: {
                Label("編集", systemImage: "pencil")
            }
            .accessibilityIdentifier("edit-constraint-\(constraint.id.uuidString)")
            Button(role: .destructive) {
                pendingDeletion = constraint
            } label: {
                Label("削除", systemImage: "trash")
            }
            .accessibilityIdentifier("delete-constraint-\(constraint.id.uuidString)")
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(AppColors.ink)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("その他")
        .accessibilityIdentifier("constraint-actions-\(constraint.id.uuidString)")
        .disabled(deletingConstraintID != nil)
    }

    private var addConstraintButton: some View {
        Button {
            editingConstraint = nil
            isEditorPresented = true
        } label: {
            Label("希望を追加", systemImage: "plus")
                .font(AppTypography.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .padding(.horizontal, AppSpacing.md)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppColors.ink)
        .background(AppColors.card)
        .overlay(Capsule().strokeBorder(AppColors.border, lineWidth: 1.5))
        .clipShape(Capsule())
        .accessibilityIdentifier("add-constraint")
    }

    private func closeEditor() {
        isEditorPresented = false
        editingConstraint = nil
    }

    private func visibilityIcon(_ visibility: ConstraintVisibility) -> String {
        switch visibility {
        case .publicToGroup: return "person.crop.circle"
        case .anonymous: return "person.crop.circle.badge.questionmark"
        case .privateToSelf: return "lock"
        }
    }

    @MainActor
    private func load() async {
        do {
            constraints = try await service.ownConstraints(participantId: participantId)
                .sorted { $0.createdAt < $1.createdAt }
        } catch {
            errorMessage = AppCopy.errorMessage(for: error)
        }
        isLoading = false
    }

    @MainActor
    private func delete(_ constraint: ConstraintService.SavedConstraint) async {
        guard deletingConstraintID == nil, preferencesOpen else {
            errorMessage = AppCopy.preferencesClosedError
            return
        }
        deletingConstraintID = constraint.id
        errorMessage = nil
        defer { deletingConstraintID = nil }
        do {
            try await service.deleteConstraint(id: constraint.id)
            constraints.removeAll { $0.id == constraint.id }
            AccessibilityNotification.Announcement("希望を削除しました").post()
        } catch {
            errorMessage = AppCopy.errorMessage(for: error)
        }
    }

    private func upsert(_ constraint: ConstraintService.SavedConstraint) {
        if let index = constraints.firstIndex(where: { $0.id == constraint.id }) {
            constraints[index] = constraint
        } else {
            constraints.append(constraint)
        }
        constraints.sort { $0.createdAt < $1.createdAt }
    }
}

private struct ConstraintEditorView: View {
    let eventId: UUID
    let participantId: UUID
    let existing: ConstraintService.SavedConstraint?
    let preferencesClosed: Bool?
    let onCancel: () -> Void
    let onSaved: (ConstraintService.SavedConstraint) -> Void
    private let service = ConstraintService()
    @State private var selectedCategory: NormalizedType?
    @State private var kind: ConstraintKind
    @State private var visibility: ConstraintVisibility
    @State private var budgetMinimum: Int
    @State private var budgetMaximum: Int
    @State private var selectedCuisines: Set<String>
    @State private var selectedAllergens: Set<String>
    @State private var selectedDietaryTags: Set<String>
    @State private var selectedRoom: String?
    @State private var travelMinutes: Int
    @State private var otherText: String
    @State private var interpretation: Interpretation?
    @State private var isParsing = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    struct Interpretation {
        var normalizedType: NormalizedType
        let normalizedValue: [String: JSONValue]
        let semanticRemainder: String?
        let sourceRawText: String
    }

    struct Payload {
        let rawText: String
        let normalizedType: NormalizedType
        let normalizedValue: [String: JSONValue]
        let semanticRemainder: String?
    }

    init(
        eventId: UUID,
        participantId: UUID,
        existing: ConstraintService.SavedConstraint?,
        preferencesClosed: Bool?,
        onCancel: @escaping () -> Void,
        onSaved: @escaping (ConstraintService.SavedConstraint) -> Void
    ) {
        self.eventId = eventId
        self.participantId = participantId
        self.existing = existing
        self.preferencesClosed = preferencesClosed
        self.onCancel = onCancel
        self.onSaved = onSaved
        let value = existing?.normalizedValue ?? [:]
        let category = existing.map {
            ConstraintCatalog.structuredCategories.contains($0.normalizedType) ? $0.normalizedType : .other
        }
        let maximum = Self.steppedValue(
            value["max_yen"]?.integerValue ?? 5_000,
            step: 500,
            range: 500...50_000,
            roundUp: true
        )
        let minimum = min(
            Self.steppedValue(
                value["min_yen"]?.integerValue ?? 0,
                step: 500,
                range: 0...30_000,
                roundUp: false
            ),
            maximum - 500
        )
        _selectedCategory = State(initialValue: category)
        _kind = State(initialValue: existing?.normalizedType.compatibleKind ?? .must)
        _visibility = State(initialValue: existing?.visibility ?? .anonymous)
        _budgetMinimum = State(initialValue: minimum)
        _budgetMaximum = State(initialValue: maximum)
        _selectedCuisines = State(initialValue: Set(value["include"]?.stringValues ?? []))
        _selectedAllergens = State(initialValue: ConstraintCatalog.selectedAllergenKeys(
            canonicalKeys: value["allergens"]?.stringValues ?? [],
            rawText: existing?.rawText ?? "",
            semanticRemainder: existing?.semanticRemainder
        ))
        _selectedDietaryTags = State(initialValue: Set(value["tags"]?.stringValues ?? []))
        _selectedRoom = State(initialValue: value["room"]?.stringValue)
        _travelMinutes = State(initialValue: Self.steppedValue(
            value["max_minutes"]?.integerValue ?? 30,
            step: 5,
            range: 10...90,
            roundUp: false
        ))
        _otherText = State(initialValue: existing?.rawText ?? "")
    }

    private var preferencesOpen: Bool { preferencesClosed == false }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.sm) {
                Text(existing == nil ? "希望を追加" : "希望を編集").font(AppTypography.title)
                Spacer()
                Button(AppCopy.cancel) { onCancel() }
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(isParsing || isSaving)
                    .accessibilityIdentifier("cancel-constraint-editor")
            }
            .padding(.horizontal, AppSpacing.lg)
            Divider().overlay(AppColors.border)
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    categorySection
                    if selectedCategory != nil {
                        structuredControl
                        prioritySection
                        sharingPicker
                    }
                    if selectedCategory == .other, interpretation != nil { clarificationSection }
                    if preferencesClosed == true {
                        Label(AppCopy.preferencesClosedError, systemImage: "lock.fill")
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.ink)
                            .accessibilityIdentifier("constraint-editor-closed")
                    } else if preferencesClosed == nil {
                        ProgressView("受付状況を確認しています")
                            .font(AppTypography.caption)
                    }
                    if let errorMessage {
                        InlineErrorView(message: errorMessage) { self.errorMessage = nil }
                    }
                    PrimaryButton(
                        title: interpretation == nil ? AppCopy.save : "確認して保存",
                        systemImage: "checkmark",
                        isLoading: isParsing || isSaving
                    ) {
                        Task { await submit() }
                    }
                    .accessibilityIdentifier(interpretation == nil ? "save-constraint" : "confirm-save-constraint")
                    .disabled(isParsing || isSaving || !canSubmit || !preferencesOpen)
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.vertical, AppSpacing.lg)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(AppColors.background)
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(AppCopy.preferenceCategory).font(AppTypography.caption.weight(.bold))
            Text(AppCopy.preferenceCategoryPrompt)
                .font(AppTypography.small)
                .foregroundStyle(AppColors.ink.opacity(0.72))
            PreferenceOptionLayout(spacing: AppSpacing.xs) {
                ForEach(ConstraintCatalog.structuredCategories) { category in categoryButton(category) }
            }
        }
        .accessibilityIdentifier("constraint-categories")
    }

    private func categoryButton(_ category: NormalizedType) -> some View {
        let selected = selectedCategory == category
        return Button {
            selectCategory(category)
        } label: {
            HStack(spacing: AppSpacing.xs) {
                Text(category.label)
                Image(systemName: "checkmark").opacity(selected ? 1 : 0).accessibilityHidden(true)
            }
            .font(AppTypography.body.weight(.semibold))
            .foregroundStyle(selected ? AppColors.accentForeground : AppColors.ink)
            .padding(.horizontal, AppSpacing.md)
            .frame(minHeight: 44)
            .background(selected ? AppColors.accent : AppColors.card)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.field, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.field).stroke(selected ? Color.clear : AppColors.border))
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected ? "選択中" : "未選択")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("constraint-category-\(category.rawValue)")
        .disabled(!preferencesOpen)
    }

    @ViewBuilder
    private var structuredControl: some View {
        switch selectedCategory {
        case .budget: budgetControl
        case .cuisine: optionControl("料理を選ぶ（複数選択可）", options: ConstraintCatalog.cuisines, selected: selectedCuisines, prefix: "constraint-cuisine") { toggle($0, in: &selectedCuisines) }
        case .allergy: allergyControl
        case .dietary: dietaryControl
        case .room: roomControl
        case .travelTime: travelTimeControl
        case .other: otherControl
        default: EmptyView()
        }
    }

    private var budgetControl: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            controlTitle("予算の範囲")
            Stepper(value: budgetMinimumBinding, in: 0...30_000, step: 500) {
                valueRow(title: "最低", value: ConstraintFormatter.yen(budgetMinimum))
            }
            .accessibilityLabel("最低予算")
            .accessibilityValue(ConstraintFormatter.yen(budgetMinimum))
            .accessibilityIdentifier("budget-min-stepper")
            Stepper(value: budgetMaximumBinding, in: 500...50_000, step: 500) {
                valueRow(title: "最高", value: ConstraintFormatter.yen(budgetMaximum))
            }
            .accessibilityLabel("最高予算")
            .accessibilityValue(ConstraintFormatter.yen(budgetMaximum))
            .accessibilityIdentifier("budget-max-stepper")
        }
        .disabled(!preferencesOpen)
        .accessibilityIdentifier("budget-controls")
    }

    private var allergyControl: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            controlTitle("アレルゲンを選ぶ（複数選択可）")
            allergenSection(title: "表示義務 9品目", options: ConstraintCatalog.mandatoryAllergens)
            allergenSection(title: "表示推奨 20品目", options: ConstraintCatalog.recommendedAllergens)
            if let remainder = existing?.semanticRemainder, !remainder.isEmpty {
                Text("一覧にない表現：\(remainder)")
                    .font(AppTypography.small)
                    .foregroundStyle(AppColors.ink.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("allergy-semantic-remainder")
            }
            safetyText(AppCopy.allergySafety)
        }
        .accessibilityIdentifier("allergy-controls")
    }

    private var dietaryControl: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            optionControl("食事の条件を選ぶ（複数選択可）", options: ConstraintCatalog.dietary, selected: selectedDietaryTags, prefix: "constraint-dietary") { toggle($0, in: &selectedDietaryTags) }
            safetyText(AppCopy.dietarySafety)
        }
        .accessibilityIdentifier("dietary-controls")
    }

    private var roomControl: some View {
        optionControl("席を選ぶ", options: ConstraintCatalog.rooms, selected: selectedRoom.map { [$0] } ?? [], prefix: "constraint-room") {
            selectedRoom = $0
            interpretation = nil
        }
        .accessibilityIdentifier("room-controls")
    }

    private var travelTimeControl: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            controlTitle("移動時間の上限")
            Stepper(value: $travelMinutes, in: 10...90, step: 5) {
                valueRow(title: "最大", value: "\(travelMinutes)分")
            }
            .accessibilityLabel("移動時間の上限")
            .accessibilityValue("\(travelMinutes)分")
            .accessibilityIdentifier("travel-time-stepper")
        }
        .disabled(!preferencesOpen)
        .accessibilityIdentifier("travel-time-controls")
    }

    private var otherControl: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            controlTitle("希望の内容")
            TextEditor(text: otherTextBinding)
                .frame(minHeight: 112)
                .padding(AppSpacing.xs)
                .background(AppColors.card)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.field, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.field).stroke(AppColors.border))
                .overlay(alignment: .topLeading) {
                    if otherText.isEmpty {
                        Text("自由に入力してください…")
                            .foregroundStyle(AppColors.ink.opacity(0.55))
                            .padding(.top, AppSpacing.sm)
                            .padding(.leading, AppSpacing.sm)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("希望の内容")
                .accessibilityIdentifier("constraint-editor-text")
                .disabled(!preferencesOpen)
        }
    }

    private var activeNormalizedType: NormalizedType {
        if let interpretation { return interpretation.normalizedType }
        if selectedCategory == .other,
           let existing,
           !ConstraintCatalog.structuredCategories.contains(existing.normalizedType),
           existing.rawText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedOtherText {
            return existing.normalizedType
        }
        return selectedCategory ?? .other
    }

    private var prioritySection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("優先度").font(AppTypography.caption.weight(.bold))
            Text(kind.title)
                .font(AppTypography.body.weight(.semibold))
                .foregroundStyle(AppColors.ink)
                .padding(.horizontal, AppSpacing.md)
                .frame(minHeight: 44)
                .background(AppColors.card)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(AppColors.border))
                .accessibilityIdentifier("constraint-priority-kind")
            Text("\(activeNormalizedType.label)は「\(kind.title)」として保存されます。")
                .font(AppTypography.small)
                .foregroundStyle(AppColors.ink.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("constraint-priority-explanation")
        }
    }

    private var sharingPicker: some View {
        HStack(spacing: AppSpacing.sm) {
            Text("公開範囲").font(AppTypography.caption.weight(.bold))
            Spacer(minLength: AppSpacing.sm)
            Picker("公開範囲", selection: $visibility) {
                ForEach(ConstraintVisibility.allCases) { option in Text(option.label).tag(option) }
            }
            .pickerStyle(.menu)
            .tint(AppColors.accent)
            .accessibilityIdentifier("constraint-visibility")
            .disabled(!preferencesOpen)
        }
        .frame(minHeight: 44)
    }

    private var clarificationSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("内容を完全には判断できませんでした。解釈と分類を確認してください。")
                .font(AppTypography.body)
                .foregroundStyle(AppColors.accent)
            if let interpretation {
                AppCard {
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text("こう解釈しました").font(AppTypography.caption.weight(.bold))
                        Text(ConstraintFormatter.summary(type: interpretation.normalizedType, value: interpretation.normalizedValue))
                            .font(AppTypography.section)
                    }
                }
                HStack(spacing: AppSpacing.sm) {
                    Text("分類").font(AppTypography.caption.weight(.bold))
                    Spacer()
                    Picker("分類", selection: normalizedTypeBinding) {
                        ForEach(ConstraintCatalog.normalizedTypes) { type in Text(type.label).tag(type) }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("constraint-normalized-type")
                }
                .frame(minHeight: 44)
            }
        }
        .accessibilityIdentifier("constraint-clarification")
    }

    private func optionControl(
        _ title: String,
        options: [ConstraintOption],
        selected: Set<String>,
        prefix: String,
        onToggle: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            controlTitle(title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), alignment: .leading)], alignment: .leading, spacing: AppSpacing.xs) {
                ForEach(options) { option in
                    SelectionChip(title: option.label, isSelected: selected.contains(option.key)) {
                        onToggle(option.key)
                    }
                    .accessibilityIdentifier("\(prefix)-\(option.key)")
                }
            }
        }
        .disabled(!preferencesOpen)
    }

    private func allergenSection(title: String, options: [ConstraintOption]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            Text(title)
                .font(AppTypography.small.weight(.semibold))
                .foregroundStyle(AppColors.ink.opacity(0.72))
            ForEach(options) { option in
                Button {
                    toggle(option.key, in: &selectedAllergens)
                } label: {
                    HStack(spacing: AppSpacing.sm) {
                        Image(systemName: selectedAllergens.contains(option.key) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedAllergens.contains(option.key) ? AppColors.accent : AppColors.ink.opacity(0.45))
                            .accessibilityHidden(true)
                        Text(option.label)
                        Spacer(minLength: 0)
                    }
                    .font(AppTypography.body)
                    .foregroundStyle(AppColors.ink)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(selectedAllergens.contains(option.key) ? "選択中" : "未選択")
                .accessibilityAddTraits(selectedAllergens.contains(option.key) ? .isSelected : [])
                .accessibilityIdentifier("constraint-allergen-\(option.key)")
                .disabled(!preferencesOpen)
            }
        }
    }

    private func controlTitle(_ title: String) -> some View {
        Text(title).font(AppTypography.caption.weight(.bold))
    }

    private func valueRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).fontWeight(.semibold)
        }
        .font(AppTypography.body)
    }

    private func safetyText(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(AppTypography.small)
            .foregroundStyle(AppColors.ink.opacity(0.72))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var budgetMinimumBinding: Binding<Int> {
        Binding(get: { budgetMinimum }, set: { budgetMinimum = min(max(0, $0), budgetMaximum - 500) })
    }

    private var budgetMaximumBinding: Binding<Int> {
        Binding(get: { budgetMaximum }, set: { budgetMaximum = max(min(50_000, $0), budgetMinimum + 500) })
    }

    private var otherTextBinding: Binding<String> {
        Binding(get: { otherText }, set: { value in
            otherText = value
            interpretation = nil
            kind = NormalizedType.other.compatibleKind
        })
    }

    private var normalizedTypeBinding: Binding<NormalizedType> {
        Binding(get: { interpretation?.normalizedType ?? .other }, set: { value in
            interpretation?.normalizedType = value
            kind = value.compatibleKind
        })
    }

    private var trimmedOtherText: String {
        otherText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        switch selectedCategory {
        case .budget, .travelTime: return true
        case .cuisine: return !selectedCuisines.isEmpty
        case .allergy: return !selectedAllergens.isEmpty
        case .dietary: return !selectedDietaryTags.isEmpty
        case .room: return selectedRoom != nil
        case .other: return !trimmedOtherText.isEmpty
        default: return false
        }
    }

    private var structuredPayload: Payload? {
        guard let selectedCategory else { return nil }
        let value: [String: JSONValue]
        let rawText: String
        let semanticRemainder: String?
        switch selectedCategory {
        case .budget:
            guard budgetMinimum < budgetMaximum else { return nil }
            value = ["min_yen": .number(Double(budgetMinimum)), "max_yen": .number(Double(budgetMaximum))]
            rawText = ConstraintFormatter.summary(type: selectedCategory, value: value)
            semanticRemainder = nil
        case .cuisine:
            let cuisines = orderedValues(selectedCuisines, options: ConstraintCatalog.cuisines)
            guard !cuisines.isEmpty else { return nil }
            value = ["include": .array(cuisines.map { .string($0) }), "exclude": .array([])]
            rawText = ConstraintFormatter.summary(type: selectedCategory, value: value)
            semanticRemainder = nil
        case .allergy:
            let labels = ConstraintCatalog.allergens.filter { selectedAllergens.contains($0.key) }.map(\.label)
            let canonical = ConstraintCatalog.canonicalAllergens(for: selectedAllergens)
            value = ["allergens": .array(canonical.map { .string($0) })]
            rawText = "アレルギー：\(labels.joined(separator: "・"))"
            semanticRemainder = nil
        case .dietary:
            let tags = orderedValues(selectedDietaryTags, options: ConstraintCatalog.dietary)
            guard !tags.isEmpty else { return nil }
            value = ["tags": .array(tags.map { .string($0) })]
            rawText = ConstraintFormatter.summary(type: selectedCategory, value: value)
            semanticRemainder = nil
        case .room:
            guard let selectedRoom else { return nil }
            value = ["room": .string(selectedRoom)]
            rawText = ConstraintFormatter.summary(type: selectedCategory, value: value)
            semanticRemainder = nil
        case .travelTime:
            value = ["max_minutes": .number(Double(travelMinutes))]
            rawText = ConstraintFormatter.summary(type: selectedCategory, value: value)
            semanticRemainder = nil
        default:
            return nil
        }
        return Payload(rawText: rawText, normalizedType: selectedCategory, normalizedValue: value, semanticRemainder: semanticRemainder)
    }

    private func orderedValues(_ selected: Set<String>, options: [ConstraintOption]) -> [String] {
        let catalogKeys = options.map(\.key)
        return catalogKeys.filter(selected.contains) + selected.subtracting(Set(catalogKeys)).sorted()
    }

    private func toggle(_ key: String, in selection: inout Set<String>) {
        if selection.contains(key) { selection.remove(key) } else { selection.insert(key) }
        interpretation = nil
    }

    private func selectCategory(_ category: NormalizedType) {
        guard selectedCategory != category else { return }
        selectedCategory = category
        interpretation = nil
        errorMessage = nil
        kind = category.compatibleKind
        guard existing == nil else { return }
        switch category {
        case .allergy, .dietary:
            visibility = .privateToSelf
        default:
            visibility = .anonymous
        }
    }

    @MainActor
    private func submit() async {
        guard preferencesOpen else {
            errorMessage = AppCopy.preferencesClosedError
            return
        }
        guard !isParsing, !isSaving, canSubmit, let selectedCategory else { return }
        if selectedCategory != .other {
            if let payload = structuredPayload { await persist(payload) }
            return
        }
        await submitOther()
    }

    @MainActor
    private func submitOther() async {
        if let interpretation,
           interpretation.sourceRawText == trimmedOtherText {
            await persist(Payload(
                rawText: trimmedOtherText,
                normalizedType: interpretation.normalizedType,
                normalizedValue: interpretation.normalizedValue,
                semanticRemainder: interpretation.semanticRemainder
            ))
            return
        }
        if let existing,
           !ConstraintCatalog.structuredCategories.contains(existing.normalizedType),
           existing.rawText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedOtherText {
            await persist(Payload(
                rawText: trimmedOtherText,
                normalizedType: existing.normalizedType,
                normalizedValue: existing.normalizedValue,
                semanticRemainder: existing.semanticRemainder
            ))
            return
        }
        await parseAndSave()
    }

    @MainActor
    private func parseAndSave() async {
        isParsing = true
        errorMessage = nil
        defer { isParsing = false }
        do {
            let result = try await service.parse(rawText: trimmedOtherText, kind: kind, language: "ja")
            let parsed = Interpretation(
                normalizedType: result.normalizedType,
                normalizedValue: result.normalizedValue,
                semanticRemainder: result.semanticRemainder,
                sourceRawText: trimmedOtherText
            )
            kind = parsed.normalizedType.compatibleKind
            if result.needsClarification {
                interpretation = parsed
            } else {
                await persist(Payload(
                    rawText: trimmedOtherText,
                    normalizedType: parsed.normalizedType,
                    normalizedValue: parsed.normalizedValue,
                    semanticRemainder: parsed.semanticRemainder
                ))
            }
        } catch {
            errorMessage = AppCopy.errorMessage(for: error)
        }
    }

    @MainActor
    private func persist(_ payload: Payload) async {
        guard !isSaving, preferencesOpen else {
            errorMessage = AppCopy.preferencesClosedError
            return
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let compatibleKind = payload.normalizedType.compatibleKind
            kind = compatibleKind
            let savedConstraint: ConstraintService.SavedConstraint
            if let existing {
                savedConstraint = try await service.updateConstraint(
                    id: existing.id,
                    kind: compatibleKind,
                    rawText: payload.rawText,
                    normalizedType: payload.normalizedType,
                    normalizedValue: payload.normalizedValue,
                    visibility: visibility,
                    semanticRemainder: payload.semanticRemainder
                )
            } else {
                savedConstraint = try await service.insertConstraint(
                    eventId: eventId,
                    participantId: participantId,
                    kind: compatibleKind,
                    rawText: payload.rawText,
                    normalizedType: payload.normalizedType,
                    normalizedValue: payload.normalizedValue,
                    visibility: visibility,
                    semanticRemainder: payload.semanticRemainder
                )
            }
            onSaved(savedConstraint)
            AccessibilityNotification.Announcement(existing == nil ? "希望を保存しました" : "希望を更新しました").post()
        } catch {
            errorMessage = AppCopy.errorMessage(for: error)
        }
    }

    private static func steppedValue(
        _ value: Int,
        step: Int,
        range: ClosedRange<Int>,
        roundUp: Bool
    ) -> Int {
        let stepped = roundUp ? ((value + step - 1) / step) * step : (value / step) * step
        return min(max(stepped, range.lowerBound), range.upperBound)
    }
}
