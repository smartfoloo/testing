import SwiftUI
import VisionKit

struct JoinEventView: View {
    private struct JoinedDestination: Hashable {
        let eventId: UUID
        let participantId: UUID
        let inviteCode: String
    }

    private let service = EventService()
    @State private var inviteCode: String
    @State private var preview: EventPreview?
    @State private var previewedCode: String?
    @State private var displayName = ""
    @State private var origin: OriginSelection? = OriginSelection.uiTestDefault
    @State private var isLocationSearchPresented = false
    @State private var isScanning = false
    @State private var isPreviewing = false
    @State private var isSubmitting = false
    @State private var joined: JoinedDestination?
    @State private var errorMessage: String?

    init(initialCode: String? = nil) {
        _inviteCode = State(initialValue: initialCode.map { Self.extractInviteCode(from: $0) } ?? "")
    }

    private var normalizedCode: String {
        inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var canJoin: Bool {
        preview?.status != .closed && previewedCode == normalizedCode &&
            !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            origin != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                codeSection
                if let preview {
                    previewCard(preview)
                    if preview.status != .closed {
                        participantForm
                    }
                }
                if let errorMessage {
                    InlineErrorView(message: errorMessage) {
                        if preview == nil {
                            Task { await loadPreview() }
                        } else {
                            self.errorMessage = nil
                        }
                    }
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xxl)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AppColors.background)
        .navigationTitle(AppCopy.join)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $joined) { destination in
            EventHomeView(
                eventId: destination.eventId,
                participantId: destination.participantId,
                inviteCode: destination.inviteCode
            )
        }
        .sheet(isPresented: $isScanning) {
            QRScannerView { scanned in
                let code = Self.extractInviteCode(from: scanned)
                isScanning = false
                inviteCode = code
                Task { await loadPreview(expectedCode: code) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $isLocationSearchPresented) {
            LocationSearchSheet { selection in origin = selection }
        }
        .task {
            if normalizedCode.count == 6 && preview == nil {
                await loadPreview()
            }
        }
    }

    private var codeSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("招待コード").font(AppTypography.section)
            TextField("6桁のコード", text: $inviteCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .appInputFieldStyle()
                .font(.system(.body, design: .monospaced))
                .accessibilityIdentifier("invite-code")
                .onChange(of: inviteCode) { _, value in
                    let normalized = String(value.lowercased().filter { !$0.isWhitespace }.prefix(6))
                    if inviteCode != normalized { inviteCode = normalized }
                    if previewedCode != normalized {
                        preview = nil
                        previewedCode = nil
                    }
                }
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
            PrimaryButton(title: "集まりを確認", isLoading: isPreviewing) {
                Task { await loadPreview() }
            }
            .accessibilityIdentifier("preview-event")
            .disabled(normalizedCode.count != 6 || isPreviewing)
        }
    }

    private func previewCard(_ preview: EventPreview) -> some View {
        AppCard {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text(preview.name).font(AppTypography.title)
                if let scheduledAt = preview.scheduledAt {
                    Label(
                        scheduledAt.formatted(date: .abbreviated, time: .shortened),
                        systemImage: "calendar"
                    )
                }
                if let organizerDisplayName = preview.organizerDisplayName {
                    Label("幹事：\(organizerDisplayName)", systemImage: "person.crop.circle")
                }
                Text("現在\(preview.participantCount)人が参加しています")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.ink.opacity(0.72))
                if preview.status == .closed {
                    Label("この集まりは終了しています", systemImage: "lock.fill")
                        .font(AppTypography.caption.weight(.semibold))
                        .foregroundStyle(AppColors.accent)
                }
            }
            .font(AppTypography.body)
        }
        .accessibilityIdentifier("event-preview")
    }

    private var participantForm: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xl) {
            Divider().overlay(AppColors.border)
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("あなたの名前").font(AppTypography.section)
                TextField("例：佐藤", text: $displayName)
                    .appInputFieldStyle()
                    .accessibilityIdentifier("join-display-name")
            }
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("出発地").font(AppTypography.section)
                Button {
                    isLocationSearchPresented = true
                } label: {
                    HStack(spacing: AppSpacing.sm) {
                        Image(systemName: origin == nil ? "magnifyingglass" : "checkmark.circle.fill")
                            .foregroundStyle(AppColors.accent)
                        Text(origin?.label ?? "駅やエリアを検索")
                            .foregroundStyle(AppColors.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(origin == nil ? "設定" : "変更")
                            .font(AppTypography.caption.weight(.bold))
                            .foregroundStyle(AppColors.accent)
                    }
                    .padding(.horizontal, AppSpacing.md)
                    .frame(minHeight: 48)
                    .background(AppColors.card)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.field, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: AppRadius.field).stroke(AppColors.border))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("join-origin-search")
                Text("移動時間の計算に使います。ほかの参加者には表示されません。")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.ink.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("上の集まりを確認してから参加してください。")
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.ink.opacity(0.72))
            PrimaryButton(title: "参加する", isLoading: isSubmitting) {
                Task { await join() }
            }
            .accessibilityIdentifier("join-submit")
            .disabled(!canJoin || isSubmitting)
        }
    }

    static func extractInviteCode(from payload: String) -> String {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed), components.scheme != nil {
            let candidate = components.queryItems?.first(where: { $0.name == "code" })?.value
                ?? components.path.split(separator: "/").last.map(String.init)
                ?? trimmed
            return String(candidate.lowercased().filter { !$0.isWhitespace }.prefix(6))
        }
        return String(trimmed.lowercased().filter { !$0.isWhitespace }.prefix(6))
    }

    @MainActor
    private func loadPreview(expectedCode: String? = nil) async {
        let code = expectedCode ?? normalizedCode
        guard code.count == 6, !isPreviewing else { return }
        isPreviewing = true
        errorMessage = nil
        defer { isPreviewing = false }
        do {
            let result = try await service.previewEvent(inviteCode: code)
            guard normalizedCode == code else { return }
            preview = result
            previewedCode = code
        } catch {
            if normalizedCode == code {
                preview = nil
                previewedCode = nil
                errorMessage = AppCopy.errorMessage(for: error)
            }
        }
    }

    @MainActor
    private func join() async {
        guard !isSubmitting, canJoin, let preview, let origin else { return }
        let code = normalizedCode
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let participantId = try await service.joinEvent(
                inviteCode: code,
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                origin: origin
            )
            joined = JoinedDestination(eventId: preview.eventId, participantId: participantId, inviteCode: code)
        } catch {
            errorMessage = AppCopy.errorMessage(for: error)
        }
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
        private var hasScanned = false
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) { handle(addedItems) }
        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) { handle([item]) }
        private func handle(_ items: [RecognizedItem]) {
            guard !hasScanned else { return }
            for case let .barcode(barcode) in items {
                if let value = barcode.payloadStringValue {
                    hasScanned = true
                    onScan(value)
                    return
                }
            }
        }
    }
}

#Preview { NavigationStack { JoinEventView() } }
