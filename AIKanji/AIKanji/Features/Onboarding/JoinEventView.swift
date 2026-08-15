import SwiftUI
import VisionKit

struct JoinEventView: View {
    private let service = EventService()

    @State private var inviteCode = ""
    @State private var displayName = ""
    @State private var travelReference: TravelReference = .office
    @State private var isScanning = false
    @State private var isSubmitting = false
    @State private var participantId: UUID?
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

            if let participantId {
                Section { Text("Joined as \(participantId.uuidString)") }
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Join Event")
        .sheet(isPresented: $isScanning) {
            QRScannerView { scanned in
                inviteCode = String(scanned.lowercased().prefix(6))
                isScanning = false
            }
            .ignoresSafeArea()
        }
    }

    private func join() async {
        isSubmitting = true
        errorMessage = nil
        do {
            participantId = try await service.joinEvent(
                inviteCode: inviteCode.trimmed,
                displayName: displayName.trimmed,
                travelReference: travelReference
            )
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
