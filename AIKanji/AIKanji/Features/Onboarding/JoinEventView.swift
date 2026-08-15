import SwiftUI
import VisionKit

struct JoinEventView: View {
    private let service = EventService()
    @State private var inviteCode: String
    @State private var displayName = ""
    @State private var travelReference: TravelReference = .office
    @State private var travelPlace: PlaceSuggestion?
    @State private var isScanning = false
    @State private var isSubmitting = false
    @State private var joined: (eventId: UUID, participantId: UUID)?
    @State private var errorMessage: String?

    /// `initialCode` is the invite-link path (PRD §3): a tapped `?code=` link lands here with
    /// the field already filled in, exactly as a scanned QR does.
    init(initialCode: String? = nil) {
        _inviteCode = State(initialValue: initialCode.map { String($0.lowercased().prefix(6)) } ?? "")
    }

    private var canSubmit: Bool {
        inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).count == 6 &&
            !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text("招待コード").font(AppTypography.section)
                    TextField("6桁のコード", text: $inviteCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .appInputFieldStyle()
                        .font(.system(.body, design: .monospaced))
                        .accessibilityIdentifier("invite-code")
                        .onChange(of: inviteCode) { _, value in inviteCode = String(value.lowercased().prefix(6)) }
                    if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                        Button {
                            isScanning = true
                        } label: {
                            Label("QRコードを読み取る", systemImage: "qrcode.viewfinder")
                        }
                        .frame(minHeight: 44)
                        .foregroundStyle(AppColors.accent)
                        .accessibilityIdentifier("scan-qr")
                    }
                }
                Divider().overlay(AppColors.border)
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text("あなたの名前").font(AppTypography.section)
                    TextField("例：佐藤", text: $displayName)
                        .appInputFieldStyle()
                        .accessibilityIdentifier("join-display-name")
                }
                TravelReferenceField(
                    reference: $travelReference,
                    place: $travelPlace,
                    identifierPrefix: "join-travel"
                )
                PrimaryButton(title: "参加する", isLoading: isSubmitting) {
                    Task { await join() }
                }
                .accessibilityIdentifier("join-submit")
                .disabled(!canSubmit || isSubmitting)
                if let joined {
                    NavigationLink(AppCopy.continueAction) {
                        EventHomeView(eventId: joined.eventId, participantId: joined.participantId, inviteCode: inviteCode)
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("continue-event")
                }
                if let errorMessage {
                    InlineErrorView(message: errorMessage) { Task { await join() } }
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xxl)
        }
        .background(AppColors.background)
        .navigationTitle(AppCopy.join)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isScanning) {
            QRScannerView { scanned in
                inviteCode = Self.extractInviteCode(from: scanned)
                isScanning = false
            }
            .ignoresSafeArea()
        }
    }

    static func extractInviteCode(from payload: String) -> String {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed), components.scheme != nil {
            let candidate = components.queryItems?.first(where: { $0.name == "code" })?.value
                ?? components.path.split(separator: "/").last.map(String.init)
                ?? trimmed
            return String(candidate.lowercased().prefix(6))
        }
        return String(trimmed.lowercased().prefix(6))
    }

    private func join() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        do {
            let participantId = try await service.joinEvent(
                inviteCode: inviteCode.trimmingCharacters(in: .whitespacesAndNewlines),
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                travelReference: travelReference,
                // Nil when the participant skipped the place, or chose どこでも: the backend
                // then leaves them out of the origins instead of guessing one.
                travelReferencePlaceId: travelPlace?.placeId
            )
            let event = try await service.event(inviteCode: inviteCode.trimmingCharacters(in: .whitespacesAndNewlines))
            joined = (event.id, participantId)
        } catch {
            errorMessage = AppCopy.networkError
        }
        isSubmitting = false
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }
    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) { handle(addedItems) }
        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) { handle([item]) }
        private func handle(_ items: [RecognizedItem]) {
            for case let .barcode(barcode) in items {
                if let value = barcode.payloadStringValue { onScan(value); return }
            }
        }
    }
}

#Preview { NavigationStack { JoinEventView() } }
