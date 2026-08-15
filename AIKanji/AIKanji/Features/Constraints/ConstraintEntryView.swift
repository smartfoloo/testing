import SwiftUI

struct ConstraintEntryView: View {
    let eventId: UUID
    let participantId: UUID
    private let service = ConstraintService()
    @State private var drafts: [ConstraintKind: String] = [.must: "", .want: ""]
    @State private var pending: PendingConstraint?
    @State private var isParsing = false
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var savedCount = 0

    struct PendingConstraint: Identifiable {
        let id = UUID()
        let kind: ConstraintKind
        let rawText: String
        var normalizedType: NormalizedType
        var normalizedValue: [String: JSONValue]
        var visibility: ConstraintVisibility
        let needsClarification: Bool
    }

    private static let examples: [ConstraintKind: [(String, String)]] = [
        .must: [("予算", "4000円以内"), ("ベジタリアン", "ベジタリアン対応"), ("個室", "個室が必要"), ("アレルギー", "えびが食べられない")],
        .want: [("料理", "和食がいい"), ("静か", "静かに話せる場所"), ("飲み物", "お酒が充実")],
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                header
                if isLoading {
                    LoadingStateView(title: "保存した希望を読み込んでいます")
                } else {
                    requirementSection(.must)
                    requirementSection(.want)
                    if savedCount > 0 {
                        Text("\(savedCount)件の希望を保存しました。")
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.ink.opacity(0.72))
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                if let errorMessage = errorMessage {
                    InlineErrorView(message: errorMessage) { self.errorMessage = nil }
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xxl)
        }
        .background(AppColors.background)
        .task {
            isLoading = false
        }
        .sheet(item: $pending) { item in
            ConstraintConfirmSheet(
                pending: Binding(
                    get: { pending ?? item },
                    set: { pending = $0 }
                )
            ) { confirmed in
                Task { await save(confirmed) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(AppCopy.homeRequirements).font(AppTypography.title)
            Text("みんなで納得できるお店の条件を教えてください。")
                .font(AppTypography.body)
                .foregroundStyle(AppColors.ink.opacity(0.72))
        }
    }

    private func requirementSection(_ kind: ConstraintKind) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(kind.title).font(AppTypography.section)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: AppSpacing.xs) {
                ForEach(Self.examples[kind] ?? [], id: \.0) { example in
                    StarterChip(title: example.0, tint: kind == .must ? AppColors.accentSoft : AppColors.yellow) {
                        drafts[kind] = example.1
                    }
                }
            }
            TextEditor(text: binding(for: kind))
                .frame(minHeight: 84)
                .padding(AppSpacing.xs)
                .background(AppColors.card)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.field, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.field).stroke(AppColors.border))
                .overlay(alignment: .topLeading) {
                    if (drafts[kind] ?? "").isEmpty {
                        Text("自由に入力してください…")
                            .foregroundStyle(AppColors.ink.opacity(0.55))
                            .padding(.top, AppSpacing.sm)
                            .padding(.leading, AppSpacing.sm)
                            .allowsHitTesting(false)
                    }
                }
            Button(isParsing ? AppCopy.loading : "次へ") {
                Task { await parse(kind: kind) }
            }
            .font(AppTypography.body.weight(.bold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, AppSpacing.lg)
            .frame(minHeight: 44)
            .background(AppColors.accent)
            .clipShape(Capsule())
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityIdentifier("next-\(kind.rawValue)")
            .disabled(isParsing || (drafts[kind] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func binding(for kind: ConstraintKind) -> Binding<String> {
        Binding(get: { drafts[kind] ?? "" }, set: { drafts[kind] = $0 })
    }

    private func parse(kind: ConstraintKind) async {
        let rawText = (drafts[kind] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else { return }
        isParsing = true
        errorMessage = nil
        do {
            let result = try await service.parse(rawText: rawText, kind: kind, language: "ja")
            pending = PendingConstraint(
                kind: kind,
                rawText: rawText,
                normalizedType: result.normalizedType,
                normalizedValue: result.normalizedValue,
                visibility: result.suggestedVisibility,
                needsClarification: result.needsClarification
            )
        } catch {
            errorMessage = AppCopy.networkError
        }
        isParsing = false
    }

    private func save(_ constraint: PendingConstraint) async {
        do {
            try await service.insertConstraint(
                eventId: eventId,
                participantId: participantId,
                kind: constraint.kind,
                rawText: constraint.rawText,
                normalizedType: constraint.normalizedType,
                normalizedValue: constraint.normalizedValue,
                visibility: constraint.visibility
            )
            drafts[constraint.kind] = ""
            savedCount += 1
            pending = nil
        } catch {
            errorMessage = AppCopy.networkError
        }
    }
}

struct ConstraintConfirmSheet: View {
    @Binding var pending: ConstraintEntryView.PendingConstraint
    let onConfirm: (ConstraintEntryView.PendingConstraint) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        BottomSheetScaffold(title: "こう解釈しました") {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Text(ConstraintFormatter.summary(type: pending.normalizedType, value: pending.normalizedValue))
                    .font(AppTypography.section)
                Text("「\(pending.rawText)」")
                    .font(AppTypography.body)
                    .foregroundStyle(AppColors.ink.opacity(0.72))
                if pending.needsClarification {
                    Text("近い分類を選んでください。")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.accent)
                }
                Picker("分類", selection: $pending.normalizedType) {
                    ForEach(NormalizedType.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                HStack {
                    SelectionChip(title: AppCopy.showName, isSelected: pending.visibility == .publicToGroup) {
                        pending.visibility = .publicToGroup
                    }
                    SelectionChip(title: AppCopy.anonymous, isSelected: pending.visibility == .anonymous) {
                        pending.visibility = .anonymous
                    }
                }
                HStack {
                    Button(AppCopy.cancel) { dismiss() }.frame(maxWidth: .infinity).frame(minHeight: 48)
                    Button(AppCopy.save) { onConfirm(pending) }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 48)
                        .buttonStyle(.borderedProminent).tint(AppColors.accent)
                        .accessibilityIdentifier("save-constraint")
                }
            }
        }
    }
}
