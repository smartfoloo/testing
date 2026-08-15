import CoreImage.CIFilterBuiltins
import SwiftUI

struct CreateEventView: View {
    private let service = EventService()
    @State private var name = ""
    @State private var displayName = ""
    @State private var objective: EventObjective = .balanced
    @State private var travelReference: TravelReference = .office
    @State private var travelPlace: PlaceSuggestion?
    @State private var inviteCode: String?
    @State private var created: (eventId: UUID, participantId: UUID)?
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var didCopy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                if let inviteCode, let created {
                    doneView(inviteCode: inviteCode, created: created)
                } else {
                    formView
                }
                if let errorMessage {
                    InlineErrorView(message: errorMessage) { Task { await create() } }
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xxl)
        }
        .background(AppColors.background)
        .navigationTitle("集まりを作る")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var formView: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xl) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("どんな集まりですか？").font(AppTypography.title)
                TextField("例：忘年会", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("event-name")
            }
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text("目的").font(AppTypography.section)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: AppSpacing.xs) {
                    ForEach(EventObjective.allCases) { value in
                        SelectionChip(title: value.label, isSelected: objective == value) { objective = value }
                    }
                }
            }
            Divider().overlay(AppColors.border)
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("あなたの名前").font(AppTypography.section)
                TextField("例：田中", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("display-name")
            }
            TravelReferenceField(
                reference: $travelReference,
                place: $travelPlace,
                identifierPrefix: "travel"
            )
            PrimaryButton(title: "集まりを作成", isLoading: isSubmitting) {
                Task { await create() }
            }
            .accessibilityIdentifier("create-submit")
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func doneView(inviteCode: String, created: (eventId: UUID, participantId: UUID)) -> some View {
        // PRD §3: invite "by link/QR". The QR encodes the link so scanning it opens the join
        // flow with the code already filled in, rather than yielding a bare code to retype.
        // With no invite domain configured there is no link, and the bare code is shared.
        let link = InviteLink.url(code: inviteCode)
        let shared = link?.absoluteString ?? inviteCode
        return VStack(alignment: .center, spacing: AppSpacing.lg) {
            Text(InviteCopy.title).font(AppTypography.title)
            Text(inviteCode)
                .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                .tracking(5)
                .foregroundStyle(AppColors.accent)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("inviteCode")
            if let image = Self.qrImage(for: shared) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(AppSpacing.md)
                    .background(AppColors.card)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.sheet, style: .continuous))
                    .frame(maxWidth: 190)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(InviteCopy.qrAccessibilityLabel)
                    .accessibilityIdentifier("inviteQRCode")
            }
            Text(link == nil ? InviteCopy.shareCodeHelp : InviteCopy.shareLinkHelp)
                .font(AppTypography.body)
                .foregroundStyle(AppColors.ink.opacity(0.72))
                .multilineTextAlignment(.center)
            if let link {
                Text(link.absoluteString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(AppColors.ink.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, AppSpacing.xs)
                    .background(AppColors.card)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.field, style: .continuous))
                    .accessibilityIdentifier("inviteLink")
            }
            HStack {
                if let link {
                    ShareLink(item: link) {
                        Label(InviteCopy.share, systemImage: "square.and.arrow.up")
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("share-invite")
                } else {
                    ShareLink(item: inviteCode) {
                        Label(InviteCopy.share, systemImage: "square.and.arrow.up")
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("share-invite")
                }
                Button {
                    UIPasteboard.general.string = shared
                    didCopy = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        didCopy = false
                    }
                } label: {
                    Label(copyTitle(hasLink: link != nil), systemImage: "doc.on.doc")
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("copy-invite")
            }
            .foregroundStyle(AppColors.accent)
            NavigationLink {
                EventHomeView(eventId: created.eventId, participantId: created.participantId, inviteCode: inviteCode)
            } label: {
                Text(AppCopy.continueAction).frame(maxWidth: .infinity).frame(minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.accent)
            .clipShape(Capsule())
            .accessibilityIdentifier("continue-event")
        }
    }

    private func copyTitle(hasLink: Bool) -> String {
        if didCopy { return InviteCopy.copied }
        return hasLink ? InviteCopy.copyLink : InviteCopy.copyCode
    }

    private func create() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        do {
            let event = try await service.createEvent(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                travelReference: travelReference,
                // The organizer is a participant too, so their origin is only real if they
                // picked a place. Nil is a valid answer: the backend reports them as
                // unresolved instead of inventing a location.
                travelReferencePlaceId: travelPlace?.placeId,
                objective: objective
            )
            created = (event.eventId, event.participantId)
            inviteCode = event.inviteCode
        } catch {
            errorMessage = AppCopy.networkError
        }
        isSubmitting = false
    }

    static func qrImage(for text: String, scale: CGFloat = 10) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Travel reference

/// 移動の基準 — the category AND the place it stands for.
///
/// `participants.travel_reference` is a CHECK-constrained UI category, so a participant who
/// only answers 「会社」 gives the recommendation engine nothing to measure travel from: the
/// backend used to geocode the literal word and quietly score everyone against a fictional
/// origin. The place id collected here is the real origin.
///
/// Shared by CreateEventView and JoinEventView rather than living in the design system,
/// which is a library of primitives — this is product logic.
struct TravelReferenceField: View {
    @Binding var reference: TravelReference
    @Binding var place: PlaceSuggestion?
    /// Both onboarding screens render this, so their identifiers stay distinguishable.
    let identifierPrefix: String

    private let service = EventService()
    @State private var query = ""
    @State private var results: [PlaceSuggestion] = []
    @State private var status: SearchStatus = .idle
    /// Bumped by 「もう一度試す」 so a retry re-runs the lookup for an unchanged query.
    @State private var attempt = 0

    private enum SearchStatus: Equatable {
        case idle, searching, empty, failed
    }

    /// Long enough that a burst of typing is one lookup, short enough to feel live.
    private static let debounceNanoseconds: UInt64 = 350_000_000
    /// Matches the Edge Function's own minimum, so a too-short query never leaves the device.
    private static let minQueryCharacters = 2
    private static let maxQueryCharacters = 120

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldSearch: Bool {
        reference.needsPlace && place == nil && trimmedQuery.count >= Self.minQueryCharacters
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(TravelCopy.sectionTitle).font(AppTypography.section)
            Text(TravelCopy.sectionHelp)
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.ink.opacity(0.72))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: AppSpacing.xs) {
                ForEach(TravelReference.allCases) { value in
                    SelectionChip(title: value.label, isSelected: reference == value) {
                        select(value)
                    }
                    .accessibilityIdentifier("\(identifierPrefix)-reference-\(value.rawValue)")
                }
            }
            if reference.needsPlace {
                if let place {
                    selectedPlaceCard(place)
                } else {
                    searchField
                }
            }
            // Skipping the place is allowed, but never silent: travel fairness is the
            // product's whole "no one carries a disproportionate burden" promise.
            if place == nil || !reference.needsPlace {
                Text(reference.needsPlace ? TravelCopy.missingPlace : TravelCopy.unconstrained)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, AppSpacing.xs)
                    .background(AppColors.greenSoft)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.field, style: .continuous))
                    .accessibilityIdentifier("\(identifierPrefix)-place-note")
            }
        }
        // One provider call per pause in typing, never one per keystroke: a new query (or a
        // retry) cancels the pending sleep and drops the in-flight answer, so a slow early
        // request cannot overwrite the results of a later, narrower one.
        .task(id: "\(attempt)-\(trimmedQuery)-\(reference.rawValue)-\(place?.placeId ?? "")") {
            guard shouldSearch else {
                results = []
                status = .idle
                return
            }
            status = .searching
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            if Task.isCancelled { return }
            do {
                let found = try await service.searchPlaces(query: trimmedQuery)
                if Task.isCancelled { return }
                results = found
                status = found.isEmpty ? .empty : .idle
            } catch {
                // A dead provider must not look like "no such place".
                if Task.isCancelled { return }
                results = []
                status = .failed
            }
        }
    }

    private func selectedPlaceCard(_ place: PlaceSuggestion) -> some View {
        AppCard {
            HStack(spacing: AppSpacing.sm) {
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text(place.name).font(AppTypography.body.weight(.semibold))
                    if let address = place.address {
                        Text(address)
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.ink.opacity(0.72))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("\(identifierPrefix)-place-selected")
                Button(TravelCopy.change) {
                    self.place = nil
                }
                .font(AppTypography.body.weight(.semibold))
                .foregroundStyle(AppColors.accent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("\(identifierPrefix)-place-clear")
            }
        }
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(reference.placeLabel).font(AppTypography.caption)
            TextField(TravelCopy.searchPlaceholder, text: $query)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .accessibilityIdentifier("\(identifierPrefix)-place-query")
                .onChange(of: query) { _, value in
                    query = String(value.prefix(Self.maxQueryCharacters))
                }
            if let statusText {
                Text(statusText)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.ink.opacity(0.72))
                    .accessibilityIdentifier("\(identifierPrefix)-place-status")
            }
            if status == .failed {
                Button(AppCopy.retry) { attempt += 1 }
                    .font(AppTypography.body.weight(.bold))
                    .foregroundStyle(AppColors.accent)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("\(identifierPrefix)-place-retry")
            }
            if !results.isEmpty {
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    ForEach(Array(results.enumerated()), id: \.element.placeId) { pair in
                        Button {
                            query = ""
                            results = []
                            status = .idle
                            place = pair.element
                        } label: {
                            HStack(spacing: AppSpacing.sm) {
                                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                                    Text(pair.element.name).font(AppTypography.body)
                                    if let address = pair.element.address {
                                        Text(address)
                                            .font(AppTypography.caption)
                                            .foregroundStyle(AppColors.ink.opacity(0.72))
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // Distinguishes a tappable candidate from the text field above.
                                Image(systemName: "arrow.right").foregroundStyle(AppColors.accent)
                            }
                            .padding(.horizontal, AppSpacing.sm)
                            .padding(.vertical, AppSpacing.xs)
                            .frame(minHeight: 44)
                            .background(AppColors.card)
                            .overlay(
                                RoundedRectangle(cornerRadius: AppRadius.field, style: .continuous)
                                    .strokeBorder(AppColors.border)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.field, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AppColors.ink)
                        .accessibilityIdentifier("\(identifierPrefix)-place-option-\(pair.offset)")
                    }
                }
                .accessibilityIdentifier("\(identifierPrefix)-place-results")
            }
        }
    }

    private var statusText: String? {
        switch status {
        case .idle: return nil
        case .searching: return TravelCopy.searching
        case .empty: return TravelCopy.noResults
        case .failed: return TravelCopy.searchFailed
        }
    }

    private func select(_ next: TravelReference) {
        query = ""
        results = []
        status = .idle
        reference = next
        // どこでも carries no location by definition; the other three keep the place so
        // relabelling 会社 as 駅 does not throw away a correct origin.
        if !next.needsPlace { place = nil }
    }
}

#Preview { NavigationStack { CreateEventView() } }
