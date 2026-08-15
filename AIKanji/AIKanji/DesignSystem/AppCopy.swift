import Foundation

enum AppCopy {
    static let appName = "まとメシ"
    static let tagline = "みんなの条件から、ちょうどいい店を。"
    static let create = "お店選びをはじめる"
    static let join = "招待コードで参加"
    static let retry = "もう一度試す"
    static let networkError = "通信できませんでした。時間をおいて、もう一度お試しください。"
    static let save = "保存する"
    static let cancel = "キャンセル"
    static let continueAction = "続ける"
    static let homeRequirements = "あなたの希望"
    static let homeGroup = "みんなの状況"
    static let homeOrganizer = "幹事"
    static let must = "絶対に必要"
    static let want = "できれば欲しい"
    static let findRestaurants = "条件に合うお店を探す"
    static let recommendations = "おすすめのお店"
    static let negotiationAccept = "変更しても大丈夫"
    static let negotiationDecline = "この条件を変えない"
    static let showName = "名前を表示"
    static let anonymous = "匿名で共有"
    static let chosen = "このお店に決まりました"
    static let noResults = "まだ条件に合うお店がありません。"
    static let loading = "読み込み中…"
    static let writingSummary = "お店の特徴をまとめています…"
    static let fallbackExplanation = "条件を満たす候補ですが、詳しい説明を取得できませんでした。"
    static let permissionError = "この操作を行う権限がありません。"
    static let invalidRequestError = "この操作は完了できませんでした。内容を確認して、もう一度お試しください。"

    // MARK: PRD §12 — progressive search and closing preference collection (organizer only)

    static let collectionProgress = "回答の集まり具合"
    static let provisionalBadge = "暫定"
    static let preferencesClosedBadge = "締め切り済み"
    static let closePreferences = "希望の受付を締め切る"
    static let closePreferencesQuestion = "希望の受付を締め切りますか？"
    static let closePreferencesConfirm = "締め切る"
    /// The three consequences the 幹事 is agreeing to, spelled out before the tap.
    static let closePreferencesEffect = "締め切ると、参加者は条件を追加・変更できなくなります。"
    static let closePreferencesNoRecompute = "締め切っても、おすすめは計算し直しません。締め切ったあとに「条件に合うお店を探す」を押すと、そのときの条件で計算します。"
    static let closePreferencesIrreversible = "締め切りは取り消せません。"
    static let recomputeRequired = "締め切ったあとの計算はまだです。「条件に合うお店を探す」を押すと、いまの条件で計算し直します。"

    static func objective(_ objective: EventObjective) -> String {
        switch objective {
        case .balanced: return "バランス"
        case .access: return "アクセス"
        case .cost: return "コスト"
        case .experience: return "体験"
        case .custom: return "その他"
        }
    }

    static func travel(_ reference: TravelReference) -> String {
        switch reference {
        case .office: return "会社"
        case .home: return "自宅"
        case .station: return "駅"
        case .doesntMatter: return "どこでも"
        }
    }

    static func normalizedType(_ type: NormalizedType) -> String {
        switch type {
        case .budget: return "予算"
        case .cuisine: return "料理"
        case .dietary: return "食事"
        case .allergy: return "アレルギー"
        case .smoking: return "喫煙"
        case .room: return "席"
        case .travelTime: return "移動時間"
        case .accessibility: return "設備"
        case .atmosphere: return "雰囲気"
        case .other: return "その他"
        }
    }

    static func visibility(_ visibility: ConstraintVisibility) -> String {
        switch visibility {
        case .publicToGroup: return showName
        case .anonymous: return anonymous
        case .privateToSelf: return "自分だけ"
        }
    }

    static func recommendation(_ label: RecommendationLabel?) -> String {
        switch label {
        case .fairest: return "全員の必須条件を満たしています"
        case .bestAccess: return "移動の負担が少ない候補です"
        case .bestValue: return "予算とのバランスが良い候補です"
        case .bestExperience: return "体験を重視した候補です"
        case .crowdPleaser: return "みんなの希望に最も近いお店です"
        case nil: return "条件に合う候補です"
        }
    }

    static func recommendationBadge(_ label: RecommendationLabel?) -> String {
        switch label {
        case .fairest: return "最も公平"
        case .bestAccess: return "アクセス良好"
        case .bestValue: return "コスパ重視"
        case .bestExperience: return "体験重視"
        case .crowdPleaser: return "みんなに好評"
        case nil: return "おすすめ"
        }
    }

    static func errorMessage(for error: Error) -> String {
        let description = error.localizedDescription.lowercased()
        if description.contains("only the organizer")
            || description.contains("not permitted")
            || description.contains("permission")
        {
            return permissionError
        }
        if description.contains("unknown restaurant")
            || description.contains("invalid")
            || description.contains("must")
        {
            return invalidRequestError
        }
        return networkError
    }

    static func room(_ value: String) -> String? {
        switch value {
        case "private": return "完全個室"
        case "semi_private": return "半個室"
        case "open": return "オープン席"
        default: return nil
        }
    }

    // MARK: - PRD §12 — progressive search readiness

    /// The raw shape of the progress: people, not constraint rows, plus the threshold.
    static func readinessCounts(_ readiness: CollectionReadiness) -> String {
        "\(readiness.participantCount)人中\(readiness.respondedCount)人が回答（目安は\(readiness.thresholdCount)人）"
    }

    /// What the current state means, in one sentence.
    static func readinessSummary(_ readiness: CollectionReadiness) -> String {
        if readiness.preferencesClosed {
            return "希望の受付は締め切り済みです。これ以上、条件は増えません。"
        }
        if readiness.isComplete {
            return "全員の回答がそろいました。"
        }
        if readiness.thresholdMet {
            return "おすすめを出せる人数に届きました。まだ回答していない人がいるので、結果は暫定です。"
        }
        let remaining = max(readiness.thresholdCount - readiness.respondedCount, 0)
        return "あと\(remaining)人の回答で、おすすめを出せる目安に届きます。"
    }

    /// What the 幹事 can do about it. PRD §12 explicitly does not want the group held up by a
    /// silent colleague, so searching early is offered — labelled as provisional, not blocked.
    static func readinessHint(_ readiness: CollectionReadiness) -> String {
        if readiness.preferencesClosed {
            return "参加者は条件を追加・変更できません。"
        }
        if readiness.isComplete {
            return "全員分の条件をもとに計算します。"
        }
        if readiness.thresholdMet {
            return "回答が増えたら、もう一度探すと結果が変わることがあります。"
        }
        return "今すぐ探すこともできます。その場合は、いまの回答だけをもとにした暫定のおすすめになります。"
    }

    /// Exactly what the 幹事 is locking in, stated before they confirm the close.
    static func closeSnapshot(_ readiness: CollectionReadiness) -> String {
        "いま締め切ると、\(readiness.participantCount)人中\(readiness.respondedCount)人の回答で確定します。"
    }

    /// 「2月3日 14:30 に締め切りました。」 — when, so "closed" is a fact and not a mood.
    static func closedAt(_ date: Date?) -> String? {
        guard let date else { return nil }
        return "\(closedAtFormatter.string(from: date)) に締め切りました。"
    }

    private static let closedAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    /// What a shortlist is actually based on. `basis` is the readiness captured when the run
    /// landed, so the label describes that run rather than whatever has changed since.
    static func resultBasis(_ basis: CollectionReadiness?) -> String {
        guard let basis else {
            return "前回の計算結果を表示しています。いまの条件で確認するには、もう一度探してください。"
        }
        if basis.preferencesClosed {
            return "締め切り後の条件（\(basis.participantCount)人中\(basis.respondedCount)人の回答）で計算した結果です。"
        }
        if basis.isComplete {
            return "全員（\(basis.participantCount)人）の条件で計算した結果です。"
        }
        return "暫定：\(basis.participantCount)人中\(basis.respondedCount)人の回答で計算した結果です。"
    }

    // MARK: - Travel-reference place picker (CreateEventView / JoinEventView)

    /// Label for the place field, phrased for the reference the participant chose.
    static func travelPlaceLabel(_ reference: TravelReference) -> String {
        switch reference {
        case .office: return "会社の場所"
        case .home: return "自宅の最寄り駅"
        case .station: return "出発する駅"
        case .doesntMatter: return "場所"
        }
    }

    // MARK: - Recommendation score breakdown (PRD §9)

    static func scoreDimension(_ dimension: ScoreDimension) -> String {
        switch dimension {
        case .travelFairness: return "移動の公平さ"
        case .travelAccess: return "移動の近さ"
        case .satisfaction: return "みんなの希望"
        case .quality: return "お店の評価"
        case .costFit:
            // Deliberately not 「安さ」: the component is 1 - price/tightest budget, i.e. how
            // much headroom is left against the tightest budget in the group, so ゆとり and
            // the 負担 spelled out in the detail add up to 100% and the polarity reads for
            // itself.
            return "予算のゆとり"
        case .accessibilityFit: return "設備への配慮"
        }
    }

    /// 0..1 → 「82%」. Clamped, because a stored value is trusted but never assumed in range.
    static func scorePercent(_ value: Double) -> String {
        let clamped = min(1, max(0, value))
        return "\(Int((clamped * 100).rounded()))%"
    }

    /// 「重み20%・寄与0.05」 — the arithmetic of one dimension, in the detail disclosure.
    static func scoreContribution(weight: Double, contribution: Double) -> String {
        "重み\(scorePercent(weight))・寄与\(String(format: "%.2f", contribution))"
    }

    /// 「重み付け合計 0.62。…」 — the total, so the six meters visibly add up to it.
    static func scoreWeightedTotal(_ objectiveScore: Double) -> String {
        "\(ScoreCopy.weightedTotal) \(String(format: "%.2f", objectiveScore))。\(ScoreCopy.weightedTotalNote)"
    }

    static func objectiveEmphasis(_ breakdown: ScoreBreakdown) -> String {
        let emphasized = breakdown.emphasizedDimensions.map { scoreDimension($0) }.joined(separator: "・")
        return "この会の目的は「\(objective(breakdown.objective))」。\(emphasized)を重めに見て並べています。"
    }

    /// One sentence per dimension, grounded in the stored breakdown (acceptance test A7).
    static func scoreDimensionEvidence(_ breakdown: ScoreBreakdown, _ dimension: ScoreDimension) -> String {
        let travel = breakdown.travel
        let quality = breakdown.quality
        let cost = breakdown.cost
        let accessibility = breakdown.accessibility
        let average = travel.averageMinutes.map { Int($0.rounded()) }

        switch dimension {
        case .travelFairness:
            if breakdown.isUnknown(dimension) {
                return "移動時間が分かっているのは\(travel.participants)人中\(travel.known)人です。負担の差はまだ比べられません。"
            }
            if travel.known < 2 {
                return "移動時間が分かっているのは\(travel.known)人分なので、差は生じていません。"
            }
            return "いちばん近い人といちばん遠い人の差は\(Int(travel.spreadMinutes.rounded()))分です。"
        case .travelAccess:
            guard !breakdown.isUnknown(dimension), let average else {
                return "平均の移動時間は、\(travel.participants)人中\(travel.known)人分しか分かっていません。"
            }
            return "\(travel.participants)人の平均の移動時間は約\(average)分です。"
        case .satisfaction:
            return "みんなの「できれば欲しい」に、\(scorePercent(breakdown.component(for: .satisfaction) ?? 0))ほど合っています。"
        case .quality:
            if quality.method == .atmosphereTagProxy {
                return "口コミ評価が取れていないため、雰囲気タグ\(quality.atmosphereTags)件からの暫定値です。低い評価という意味ではありません。"
            }
            let rating = quality.rating.map { number($0) } ?? "—"
            let count = quality.userRatingCount.map { String($0) } ?? "—"
            return "口コミ\(rating)（\(count)件）をもとに、件数の少なさを補正して見ています。"
        case .costFit:
            guard let priceYen = cost.priceYen else {
                return "価格が取れていないため、負担\(scorePercent(cost.burden))のいちばん厳しい見立てにしています。"
            }
            if let tightest = cost.tightestBudgetYen {
                return "1人\(priceYen)円。いちばん厳しい予算\(tightest)円に対して、負担は\(scorePercent(cost.burden))です。"
            }
            return "1人\(priceYen)円。予算の希望がないため、目安の\(cost.referenceYen)円に対して負担は\(scorePercent(cost.burden))です。"
        case .accessibilityFit:
            if accessibility.requests == 0 {
                return "設備についての希望は出ていません。"
            }
            if !accessibility.dataPresent {
                return "お店の設備情報が取れていないため、希望\(accessibility.needs.count)件（\(needList(accessibility.needs))）を確認できていません。"
            }
            if !accessibility.unmetNeeds.isEmpty {
                return "希望\(accessibility.needs.count)件のうち\(accessibility.unmetNeeds.count)件（\(needList(accessibility.unmetNeeds))）が未対応で、負担は\(scorePercent(accessibility.burden))です。"
            }
            return "希望された設備（\(needList(accessibility.needs))）に対応しています。"
        }
    }

    /// The one-line "what we could not check" summary. Named by source rather than by
    /// dimension, because one missing travel matrix darkens two dimensions at once.
    static func scoreDataGapNote(_ breakdown: ScoreBreakdown) -> String? {
        var missing: [String] = []
        if !breakdown.travel.complete || breakdown.travel.known == 0 {
            missing.append("移動時間（\(breakdown.travel.participants)人中\(breakdown.travel.known)人分）")
        }
        if breakdown.quality.method == .atmosphereTagProxy { missing.append("口コミ評価") }
        if breakdown.cost.priceYen == nil { missing.append("価格") }
        if !breakdown.accessibility.dataPresent && breakdown.accessibility.requests > 0 {
            missing.append("設備情報")
        }
        guard !missing.isEmpty else { return nil }
        return "未取得：\(missing.joined(separator: "・"))。データがないだけで、低い評価という意味ではありません。"
    }

    private static func accessibilityNeedLabel(_ need: String) -> String {
        switch need {
        case "wheelchair": return "車椅子対応"
        case "step_free": return "段差なし"
        case "elevator": return "エレベーター"
        default: return need
        }
    }

    private static func needList(_ needs: [String]) -> String {
        needs.map { accessibilityNeedLabel($0) }.joined(separator: "・")
    }

    /// 4.0 reads as 「4」, 4.2 as 「4.2」 — the same rule `JSONValue.displayText` uses.
    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

/// PRD §9 forbids presenting one opaque universal score, so the card names every dimension,
/// the emphasis this event's objective put on it and — separately — whether the underlying
/// data exists at all. Mirrors `ScoreCopy` in web/src/design/copy.ts.
enum ScoreCopy {
    static let showDetail = "内訳を見る"
    static let hideDetail = "内訳を閉じる"
    /// Shown instead of a percentage when the stored number is a missing-data placeholder.
    static let unknown = "未確認"
    /// The two polarities on one screen: components are higher-better, burdens are
    /// higher-worse. Said plainly so a bar is never misread.
    static let scaleNote = "バーは、長いほど良い項目です。予算と設備は「負担」も書いていますが、負担は数字が大きいほど、だれかの負担が重いという意味です。"
    static let legendNote = "● はこの会で重視した項目です。データがそろっていない項目は「未確認」と出します。評価が低いという意味ではありません。"
    static let weightedTotal = "重み付け合計"
    static let weightedTotalNote = "この6項目に、この会の重みをかけて足した値です（0〜1）。"
    static let detailAccessibilityLabel = "スコアの内訳"
}

/// `travel_reference` is a category, not a place, so the participant also picks a real place
/// for it. These strings explain that without jargon, and — because the place is optional —
/// name the consequence of skipping it, since travel fairness degrades silently otherwise.
enum TravelCopy {
    static let sectionTitle = "移動の基準"
    static let sectionHelp = "よく使う場所を選ぶと、みんなの移動の負担を公平に計算できます。"
    static let searchPlaceholder = "例：渋谷駅"
    static let searching = "探しています…"
    static let noResults = "見つかりませんでした。駅名や地名で試してください。"
    static let searchFailed = "場所を検索できませんでした。"
    static let change = "変更する"
    /// Shown while a location-bearing reference has no place yet.
    static let missingPlace = "場所は未設定です。このまま進めますが、移動のしやすさの計算には入りません。"
    /// Shown for どこでも, which is a valid answer and needs no place.
    static let unconstrained = "移動の条件は出しません。ほかの人が集まりやすい場所に合わせます。"
}

/// The invite hand-off (PRD §3: by link/QR, not just a code).
enum InviteCopy {
    static let title = "招待コード"
    /// Used when `InviteLink.base` is configured and there is a real link to hand over.
    static let shareLinkHelp = "リンクかQRコードを共有して、みんなを招待しましょう。"
    /// Fallback wording when no invite domain is configured, so the code is all we can share.
    static let shareCodeHelp = "このコードを共有して、みんなを招待しましょう。"
    static let share = "共有する"
    static let copyLink = "リンクをコピー"
    static let copyCode = "コピー"
    static let copied = "コピーしました"
    static let qrAccessibilityLabel = "招待コードのQRコード"
}
