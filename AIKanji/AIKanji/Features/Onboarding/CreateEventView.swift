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
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text("移動の基準").font(AppTypography.section)
                HStack {
                    ForEach([TravelReference.office, .home, .station]) { value in
                        SelectionChip(title: value.label, isSelected: travelReference == value) { travelReference = value }
                    }
                }
            }
            PrimaryButton(title: "集まりを作成", isLoading: isSubmitting) {
                Task { await create() }
            }
            .accessibilityIdentifier("create-submit")
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func doneView(inviteCode: String, created: (eventId: UUID, participantId: UUID)) -> some View {
        VStack(alignment: .center, spacing: AppSpacing.lg) {
            Text("招待コード").font(AppTypography.title)
            Text(inviteCode)
                .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                .tracking(5)
                .foregroundStyle(AppColors.accent)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("inviteCode")
            if let image = Self.qrImage(for: inviteCode) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(AppSpacing.md)
                    .background(AppColors.card)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.sheet, style: .continuous))
                    .frame(maxWidth: 190)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("招待コードのQRコード")
                    .accessibilityIdentifier("inviteQRCode")
            }
            Text("このコードを共有して、みんなを招待しましょう。")
                .font(AppTypography.body)
                .foregroundStyle(AppColors.ink.opacity(0.72))
                .multilineTextAlignment(.center)
            HStack {
                ShareLink(item: inviteCode) {
                    Label("共有する", systemImage: "square.and.arrow.up")
                }
                .frame(minHeight: 44)
                Button {
                    UIPasteboard.general.string = inviteCode
                } label: {
                    Label("コピー", systemImage: "doc.on.doc")
                }
                .frame(minHeight: 44)
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

    private func create() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        do {
            let event = try await service.createEvent(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                travelReference: travelReference,
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

#Preview { NavigationStack { CreateEventView() } }
