import Combine
import CoreImage.CIFilterBuiltins
import MapKit
import SwiftUI

struct CreateEventView: View {
    private struct CreatedDestination: Hashable {
        let eventId: UUID
        let participantId: UUID
        let inviteCode: String
    }

    private let service = EventService()
    @State private var name = ""
    @State private var displayName = ""
    @State private var includesDate = false
    @State private var scheduledAt = Date().addingTimeInterval(24 * 60 * 60)
    @State private var origin: OriginSelection? = OriginSelection.uiTestDefault
    @State private var isLocationSearchPresented = false
    @State private var inviteCode: String?
    @State private var created: (eventId: UUID, participantId: UUID)?
    @State private var destination: CreatedDestination?
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var didCopy = false
    @State private var isKeyboardVisible = false

    private var latestAllowedDate: Date {
        Calendar.current.date(byAdding: .year, value: 5, to: Date()) ?? .distantFuture
    }

    private var isFormVisible: Bool { inviteCode == nil || created == nil }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            origin != nil &&
            (!includesDate || (scheduledAt > Date() && scheduledAt <= latestAllowedDate))
    }

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
        .scrollDismissesKeyboard(.interactively)
        .background(AppColors.background)
        .safeAreaInset(edge: .bottom) {
            if isFormVisible && !isKeyboardVisible {
                submitControl
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.top, AppSpacing.sm)
                    .padding(.bottom, AppSpacing.xs)
                    .background { AppColors.background.ignoresSafeArea(edges: .bottom) }
                    .overlay(alignment: .top) { Divider().overlay(AppColors.border) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .keyboard) {
                if isFormVisible {
                    submitControl
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, AppSpacing.lg)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .navigationTitle("集まりを作る")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $destination) { destination in
            EventHomeView(
                eventId: destination.eventId,
                participantId: destination.participantId,
                inviteCode: destination.inviteCode
            )
        }
        .sheet(isPresented: $isLocationSearchPresented) {
            LocationSearchSheet { selection in origin = selection }
        }
    }

    private var submitControl: some View {
        PrimaryButton(title: "集まりを作成", isLoading: isSubmitting) {
            Task { await create() }
        }
        .accessibilityIdentifier("create-submit")
        .disabled(!canSubmit || isSubmitting)
    }

    private var formView: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xl) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("どんな集まりですか？").font(AppTypography.title)
                TextField("例：忘年会", text: $name)
                    .appInputFieldStyle()
                    .accessibilityIdentifier("event-name")
            }
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Toggle("日時を設定する", isOn: $includesDate)
                    .font(AppTypography.section)
                    .accessibilityIdentifier("include-date")
                if includesDate {
                    DatePicker(
                        "集まりの日時",
                        selection: $scheduledAt,
                        in: Date()...latestAllowedDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.compact)
                    .accessibilityIdentifier("scheduled-at")
                    Text("これからの日時を選んでください。")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.ink.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider().overlay(AppColors.border)
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("あなたの名前").font(AppTypography.section)
                TextField("例：田中", text: $displayName)
                    .appInputFieldStyle()
                    .accessibilityIdentifier("display-name")
            }
            locationSection
        }
    }

    private var locationSection: some View {
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
            .accessibilityIdentifier("origin-search")
            Text("移動時間の計算に使います。ほかの参加者には表示されません。")
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.ink.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func doneView(inviteCode: String, created: (eventId: UUID, participantId: UUID)) -> some View {
        let link = InviteLink.url(code: inviteCode)
        let shared = InviteLink.shareText(code: inviteCode)
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
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppSpacing.lg) {
                    shareLink(inviteCode: inviteCode)
                    copyButton(shared: shared, hasLink: link != nil)
                }
                VStack(spacing: AppSpacing.xs) {
                    shareLink(inviteCode: inviteCode)
                    copyButton(shared: shared, hasLink: link != nil)
                }
            }
            .foregroundStyle(AppColors.accent)
            PrimaryButton(title: AppCopy.continueAction) {
                destination = CreatedDestination(
                    eventId: created.eventId,
                    participantId: created.participantId,
                    inviteCode: inviteCode
                )
            }
            .accessibilityIdentifier("continue-event")
        }
    }

    private func shareLink(inviteCode: String) -> some View {
        var lines = ["まとメシ「\(name)」への招待"]
        if includesDate {
            lines.append("日時：\(scheduledAt.formatted(date: .abbreviated, time: .shortened))")
        }
        lines.append("招待：\(InviteLink.shareText(code: inviteCode))")
        return ShareLink(item: lines.joined(separator: "\n")) {
            Label(InviteCopy.share, systemImage: "square.and.arrow.up")
                .frame(minHeight: 44)
        }
        .accessibilityIdentifier("share-invite")
    }

    private func copyButton(shared: String, hasLink: Bool) -> some View {
        Button {
            UIPasteboard.general.string = shared
            didCopy = true
            Task {
                try? await Task.sleep(for: .seconds(1.8))
                didCopy = false
            }
        } label: {
            Label(didCopy ? InviteCopy.copied : hasLink ? InviteCopy.copyLink : InviteCopy.copyCode, systemImage: "doc.on.doc")
                .frame(minHeight: 44)
        }
        .accessibilityIdentifier("copy-invite")
    }

    @MainActor
    private func create() async {
        guard !isSubmitting, canSubmit, let origin else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let event = try await service.createEvent(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                scheduledAt: includesDate ? scheduledAt : nil,
                origin: origin,
                objective: .balanced
            )
            created = (event.eventId, event.participantId)
            inviteCode = event.inviteCode
        } catch {
            errorMessage = AppCopy.errorMessage(for: error)
        }
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

@MainActor
final class LocationSearchModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query = "" {
        didSet { completer.queryFragment = query }
    }
    @Published var completions: [MKLocalSearchCompletion] = []
    @Published var isResolving = false
    @Published var errorMessage: String?

    private let completer = MKLocalSearchCompleter()
    private let region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671),
        span: MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 4)
    )

    override init() {
        super.init()
        completer.delegate = self
        completer.region = region
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        completions = Array(completer.results.prefix(12))
        errorMessage = nil
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        completions = []
        errorMessage = "場所を検索できませんでした。"
    }

    func resolve(_ completion: MKLocalSearchCompletion) async -> OriginSelection? {
        guard !isResolving else { return nil }
        isResolving = true
        errorMessage = nil
        defer { isResolving = false }
        do {
            let request = MKLocalSearch.Request(completion: completion)
            request.region = region
            guard let item = try await MKLocalSearch(request: request).start().mapItems.first else {
                errorMessage = "場所を確認できませんでした。"
                return nil
            }
            let subtitle = completion.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = subtitle.isEmpty ? completion.title : "\(completion.title)、\(subtitle)"
            return OriginSelection(
                label: label,
                latitude: item.placemark.coordinate.latitude,
                longitude: item.placemark.coordinate.longitude
            )
        } catch {
            errorMessage = "場所を確認できませんでした。"
            return nil
        }
    }
}

struct LocationSearchSheet: View {
    let onSelect: (OriginSelection) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = LocationSearchModel()

    var body: some View {
        NavigationStack {
            List {
                if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("駅名やエリア名を入力して、候補から選んでください。")
                        .font(AppTypography.body)
                        .foregroundStyle(AppColors.ink.opacity(0.72))
                } else if model.completions.isEmpty && !model.isResolving {
                    Text(model.errorMessage ?? "候補を探しています…")
                        .font(AppTypography.body)
                        .foregroundStyle(AppColors.ink.opacity(0.72))
                } else {
                    ForEach(Array(model.completions.enumerated()), id: \.offset) { _, completion in
                        Button {
                            Task {
                                if let selection = await model.resolve(completion) {
                                    onSelect(selection)
                                    dismiss()
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                                Text(completion.title)
                                    .font(AppTypography.body)
                                    .foregroundStyle(AppColors.ink)
                                if !completion.subtitle.isEmpty {
                                    Text(completion.subtitle)
                                        .font(AppTypography.caption)
                                        .foregroundStyle(AppColors.ink.opacity(0.72))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $model.query, prompt: "駅名・エリア名")
            .navigationTitle("出発地を選ぶ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppCopy.cancel) { dismiss() }
                }
            }
            .overlay {
                if model.isResolving {
                    ProgressView("場所を確認しています…")
                        .padding(AppSpacing.lg)
                        .background(AppColors.card)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
                }
            }
        }
    }
}

#Preview { NavigationStack { CreateEventView() } }
