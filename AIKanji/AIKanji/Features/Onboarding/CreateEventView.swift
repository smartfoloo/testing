import CoreImage.CIFilterBuiltins
import SwiftUI

struct CreateEventView: View {
    private let service = EventService()

    @State private var name = ""
    @State private var displayName = ""
    @State private var objective: EventObjective = .balanced
    @State private var travelReference: TravelReference = .office
    @State private var inviteCode: String?
    @State private var created: (eventId: UUID, participantId: UUID)?
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if let inviteCode {
                Section("Invite code") {
                    Text(inviteCode)
                        .font(.system(.largeTitle, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("inviteCode")
                    if let image = Self.qrImage(for: inviteCode) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 220)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("inviteQRCode")
                    }
                    if let created {
                        NavigationLink("Continue") {
                            EventHomeView(
                                eventId: created.eventId,
                                participantId: created.participantId,
                                inviteCode: inviteCode
                            )
                        }
                    }
                }
            } else {
                Section("Event") {
                    TextField("Event name", text: $name)
                    Picker("Objective", selection: $objective) {
                        ForEach(EventObjective.allCases) { Text($0.rawValue.capitalized).tag($0) }
                    }
                }
                Section("You") {
                    TextField("Your name", text: $displayName)
                    Picker("Travel reference", selection: $travelReference) {
                        ForEach(TravelReference.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section {
                    Button(isSubmitting ? "Creating…" : "Create Event") {
                        Task { await create() }
                    }
                    .disabled(isSubmitting || name.trimmed.isEmpty || displayName.trimmed.isEmpty)
                }
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Create Event")
    }

    private func create() async {
        isSubmitting = true
        errorMessage = nil
        do {
            let event = try await service.createEvent(
                name: name.trimmed,
                displayName: displayName.trimmed,
                travelReference: travelReference,
                objective: objective
            )
            created = (event.eventId, event.participantId)
            inviteCode = event.inviteCode
        } catch {
            errorMessage = error.localizedDescription
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

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

#Preview {
    NavigationStack { CreateEventView() }
}
