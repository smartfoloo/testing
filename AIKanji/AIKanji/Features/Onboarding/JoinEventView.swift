import SwiftUI
import VisionKit

struct JoinEventView: View {
    private let service = EventService()

    @State private var inviteCode = ""
    @State private var displayName = ""
    @State private var travelReference: TravelReference = .office
    @State private var isScanning = false
    @State private var isSubmitting = false
    @State private var joined: (eventId: UUID, participantId: UUID)?
    @State private var errorMessage: String?

    private var canSubmit: Bool {
        inviteCode.trimmed.count == 6 && !displayName.trimmed.isEmpty && !isSubmitting
    }

    var body: some View {
        Form {
            Section("Invite code") {
                TextField("6-character code", text: $inviteCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: inviteCode) { _, newValue in
                        inviteCode = String(newValue.lowercased().prefix(6))
                    }
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    Button("Scan QR") { isScanning = true }
                }
            }

            Section("You") {
                TextField("Your name", text: $displayName)
                Picker("Travel reference", selection: $travelReference) {
                    ForEach(TravelReference.allCases) { Text($0.label).tag($0) }
                }
            }

            Section {
                Button(isSubmitting ? "Joining…" : "Join Event") {
                    Task { await join() }
                }
                .disabled(!canSubmit)
            }

            if let joined {
                Section {
                    NavigationLink("Continue") {
                        EventHomeView(
                            eventId: joined.eventId,
                            participantId: joined.participantId,
                            inviteCode: inviteCode
                        )
                    }
                }
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Join Event")
        .sheet(isPresented: $isScanning) {
            QRScannerView { scanned in
                inviteCode = Self.extractInviteCode(from: scanned)
                isScanning = false
            }
            .ignoresSafeArea()
        }
    }

    /// Accepts either a bare invite code or a URL carrying one (`?code=` query item
    /// or last path component), so QR payloads can evolve without breaking the scanner.
    static func extractInviteCode(from payload: String) -> String {
        let trimmed = payload.trimmed
        if let components = URLComponents(string: trimmed), components.scheme != nil {
            let candidate = components.queryItems?.first(where: { $0.name == "code" })?.value
                ?? components.path.split(separator: "/").last.map(String.init)
                ?? trimmed
            return String(candidate.lowercased().prefix(6))
        }
        return String(trimmed.lowercased().prefix(6))
    }

    private func join() async {
        isSubmitting = true
        errorMessage = nil
        do {
            let participantId = try await service.joinEvent(
                inviteCode: inviteCode.trimmed,
                displayName: displayName.trimmed,
                travelReference: travelReference
            )
            let event = try await service.event(inviteCode: inviteCode.trimmed)
            joined = (event.id, participantId)
        } catch {
            errorMessage = error.localizedDescription
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

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            handle(addedItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            handle([item])
        }

        private func handle(_ items: [RecognizedItem]) {
            for case let .barcode(barcode) in items {
                if let value = barcode.payloadStringValue {
                    onScan(value)
                    return
                }
            }
        }
    }
}

#Preview {
    NavigationStack { JoinEventView() }
}
