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
}
