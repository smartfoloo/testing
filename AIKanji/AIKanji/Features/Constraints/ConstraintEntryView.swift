import SwiftUI

struct ConstraintEntryView: View {
    let eventId: UUID
    let participantId: UUID

    private let service = ConstraintService()

    @State private var drafts: [ConstraintKind: String] = [.must: "", .want: ""]
    @State private var pending: PendingConstraint?
    @State private var isParsing = false
    @State private var errorMessage: String?
    @State private var savedCount = 0

    /// A parsed-but-not-yet-saved constraint the participant can correct before it is written.
    struct PendingConstraint: Identifiable {
        let id = UUID()
        let kind: ConstraintKind
        let rawText: String
        var normalizedType: NormalizedType
        var normalizedValue: [String: JSONValue]
        var visibility: ConstraintVisibility
        let needsClarification: Bool
    }

    private static let examples: [ConstraintKind: [(chip: String, starter: String)]] = [
        .must: [
            ("Budget", "Budget up to ¥4000"),
            ("Vegetarian", "I need vegetarian options"),
            ("Private room", "We need a private room"),
            ("Allergy", "I'm allergic to "),
        ],
        .want: [
            ("Cuisine", "I'd like Japanese food"),
            ("Quiet", "Somewhere quiet to talk"),
            ("Good drinks", "Good drinks selection"),
        ],
    ]

    var body: some View {
        Form {
            ForEach(ConstraintKind.allCases) { kind in
                Section(kind.title) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 8) {
                        ForEach(Self.examples[kind] ?? [], id: \.chip) { example in
                            Button(example.chip) { drafts[kind] = example.starter }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    TextField("Add your own…", text: binding(for: kind), axis: .vertical)
                    Button(isParsing ? "Parsing…" : "Next") {
                        Task { await parse(kind: kind) }
                    }
                    .accessibilityIdentifier("next-\(kind.rawValue)")
                    .disabled(isParsing || (drafts[kind] ?? "").trimmed.isEmpty)
                }
            }

            if savedCount > 0 {
                Section { Text("Saved \(savedCount) constraint(s).").foregroundStyle(.secondary) }
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Your requirements")
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

    private func binding(for kind: ConstraintKind) -> Binding<String> {
        Binding(get: { drafts[kind] ?? "" }, set: { drafts[kind] = $0 })
    }

    private func parse(kind: ConstraintKind) async {
        let rawText = (drafts[kind] ?? "").trimmed
        isParsing = true
        errorMessage = nil
        do {
            let result = try await service.parse(rawText: rawText, kind: kind, language: language(of: rawText))
            pending = PendingConstraint(
                kind: kind,
                rawText: rawText,
                normalizedType: result.normalizedType,
                normalizedValue: result.normalizedValue,
                visibility: result.suggestedVisibility,
                needsClarification: result.needsClarification
            )
        } catch {
            errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
        }
    }

    private func language(of text: String) -> String {
        text.range(of: "\\p{Hiragana}|\\p{Katakana}|\\p{Han}", options: .regularExpression) != nil ? "ja" : "en"
    }
}

/// Editable summary of the parse result: type, value and visibility, all overridable.
struct ConstraintConfirmSheet: View {
    @Binding var pending: ConstraintEntryView.PendingConstraint
    let onConfirm: (ConstraintEntryView.PendingConstraint) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("We read this as") {
                    Text(ConstraintFormatter.summary(type: pending.normalizedType, value: pending.normalizedValue))
                        .font(.headline)
                    Text(pending.rawText).foregroundStyle(.secondary)
                    if pending.needsClarification {
                        Text("We weren't sure — please pick the right category.")
                            .foregroundStyle(.orange)
                    }
                }

                Section("Category") {
                    Picker("Category", selection: $pending.normalizedType) {
                        ForEach(NormalizedType.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                }

                Section("Who sees your name") {
                    Picker("Visibility", selection: $pending.visibility) {
                        Text(ConstraintVisibility.publicToGroup.label).tag(ConstraintVisibility.publicToGroup)
                        Text(ConstraintVisibility.anonymous.label).tag(ConstraintVisibility.anonymous)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Button("Save") { onConfirm(pending) }
                }
            }
            .navigationTitle("Confirm")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
