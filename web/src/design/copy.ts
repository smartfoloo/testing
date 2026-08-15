/**
 * Ported 1:1 from AIKanji/AIKanji/DesignSystem/AppCopy.swift.
 * The app is Japanese-only, so these strings are the product surface — keep them verbatim.
 */

import { SCORE_DIMENSIONS } from '../models/types'
import type {
  CollectionReadiness,
  ConstraintKind,
  ConstraintVisibility,
  EventObjective,
  NormalizedType,
  ObjectiveWeights,
  RecommendationLabel,
  ScoreBreakdown,
  ScoreDimension,
  TravelReference,
} from '../models/types'

export const AppCopy = {
  appName: 'まとメシ',
  tagline: 'みんなの条件から、ちょうどいい店を。',
  create: 'お店選びをはじめる',
  join: '招待コードで参加',
  /* Optional email login (LoginSheet / Welcome), verbatim from AppCopy.swift. */
  login: 'ログイン',
  logout: 'ログアウト',
  optionalLogin: 'ログインは任意です。匿名のままでも利用できます。',
  loginCaveat: '匿名で参加した集まりは、ログイン後のアカウントには引き継がれません。',
  email: 'メールアドレス',
  password: 'パスワード',
  loginSubmit: 'ログインする',
  /**
   * The signed-in heading. Inlined in LoginSheet.swift's `signedInView` rather than named
   * in AppCopy, so it is added here to keep the two sheets word-for-word identical.
   */
  signedIn: 'ログイン中',
  retry: 'もう一度試す',
  networkError: '通信できませんでした。時間をおいて、もう一度お試しください。',
  save: '保存する',
  cancel: 'キャンセル',
  continueAction: '続ける',
  homeRequirements: 'あなたの希望',
  homeGroup: 'みんなの状況',
  homeOrganizer: '幹事',
  must: '絶対に必要',
  want: 'できれば欲しい',
  findRestaurants: '条件に合うお店を探す',
  recommendations: 'おすすめのお店',
  negotiationAccept: '変更しても大丈夫',
  negotiationDecline: 'この条件を変えない',
  showName: '名前を表示',
  anonymous: '匿名で共有',
  chosen: 'このお店に決まりました',
  noResults: 'まだ条件に合うお店がありません。',
  loading: '読み込み中…',
  writingSummary: 'お店の特徴をまとめています…',
  fallbackExplanation: '条件を満たす候補ですが、詳しい説明を取得できませんでした。',
  permissionError: 'この操作を行う権限がありません。',
  /** Verbatim from AppCopy.invalidCredentialsError on iOS. */
  invalidCredentialsError: 'メールアドレスまたはパスワードが正しくありません。',
  invalidRequestError:
    'この操作は完了できませんでした。内容を確認して、もう一度お試しください。',

  /* PRD §12 — progressive search and closing preference collection (organizer only). */
  collectionProgress: '回答の集まり具合',
  provisionalBadge: '暫定',
  preferencesClosedBadge: '締め切り済み',
  closePreferences: '希望の受付を締め切る',
  closePreferencesQuestion: '希望の受付を締め切りますか？',
  closePreferencesConfirm: '締め切る',
  /** The three consequences the 幹事 is agreeing to, spelled out before the tap. */
  closePreferencesEffect: '締め切ると、参加者は条件を追加・変更できなくなります。',
  closePreferencesNoRecompute:
    '締め切っても、おすすめは計算し直しません。締め切ったあとに「条件に合うお店を探す」を押すと、そのときの条件で計算します。',
  closePreferencesIrreversible: '締め切りは取り消せません。',
  recomputeRequired:
    '締め切ったあとの計算はまだです。「条件に合うお店を探す」を押すと、いまの条件で計算し直します。',
} as const

export function objectiveLabel(objective: EventObjective): string {
  switch (objective) {
    case 'balanced':
      return 'バランス'
    case 'access':
      return 'アクセス'
    case 'cost':
      return 'コスト'
    case 'experience':
      return '体験'
    case 'custom':
      return 'その他'
  }
}

export function travelLabel(reference: TravelReference): string {
  switch (reference) {
    case 'office':
      return '会社'
    case 'home':
      return '自宅'
    case 'station':
      return '駅'
    case 'doesnt_matter':
      return 'どこでも'
  }
}

export function normalizedTypeLabel(type: NormalizedType): string {
  switch (type) {
    case 'budget':
      return '予算'
    case 'cuisine':
      return '料理'
    case 'dietary':
      return '食事'
    case 'allergy':
      return 'アレルギー'
    case 'smoking':
      return '喫煙'
    case 'room':
      return '席'
    case 'travel_time':
      return '移動時間'
    case 'accessibility':
      return '設備'
    case 'atmosphere':
      return '雰囲気'
    case 'other':
      return 'その他'
  }
}

export function visibilityLabel(visibility: ConstraintVisibility): string {
  switch (visibility) {
    case 'PUBLIC':
      return AppCopy.showName
    case 'ANONYMOUS':
      return AppCopy.anonymous
    case 'PRIVATE':
      return '自分だけ'
  }
}

export function kindTitle(kind: ConstraintKind): string {
  return kind === 'MUST' ? AppCopy.must : AppCopy.want
}

export function recommendationText(label: RecommendationLabel | null): string {
  switch (label) {
    case 'fairest':
      return '全員の必須条件を満たしています'
    case 'best_access':
      return '移動の負担が少ない候補です'
    case 'best_value':
      return '予算とのバランスが良い候補です'
    case 'best_experience':
      return '体験を重視した候補です'
    case 'crowd_pleaser':
      return 'みんなの希望に最も近いお店です'
    default:
      return '条件に合う候補です'
  }
}

export function recommendationBadge(label: RecommendationLabel | null): string {
  switch (label) {
    case 'fairest':
      return '最も公平'
    case 'best_access':
      return 'アクセス良好'
    case 'best_value':
      return 'コスパ重視'
    case 'best_experience':
      return '体験重視'
    case 'crowd_pleaser':
      return 'みんなに好評'
    default:
      return 'おすすめ'
  }
}

export function smokingLabel(value: string): string | null {
  switch (value) {
    case 'non_smoking':
      return '禁煙'
    case 'smoking_ok':
      return '喫煙可'
    default:
      return null
  }
}

export function roomLabel(value: string): string | null {
  switch (value) {
    case 'private':
      return '完全個室'
    case 'semi_private':
      return '半個室'
    case 'open':
      return 'オープン席'
    default:
      return null
  }
}

/* -------------------------------------------------------------------------- */
/* Taxonomy tag vocabularies (the app has no English surface)                   */
/* -------------------------------------------------------------------------- */

/*
 * `normalized_value` stores taxonomy tags as English identifiers — llm-assist's
 * SYSTEM_PROMPT fixes the shapes (dietary/atmosphere `{"tags": []}`, allergy
 * `{"allergens": []}`, cuisine `{"include": [], "exclude": []}`) and its examples are English
 * words — so printing them verbatim put 「雰囲気：quiet」 and 「アレルギー：shellfish」 in an
 * otherwise fully Japanese interface. Each vocabulary therefore gets a lookup with the same
 * contract as `roomLabel` / `smokingLabel` / `accessibilityNeedLabel` above: a Japanese label
 * for a value we actually produce, and `null` for everything else so the caller falls through
 * to the stored tag.
 *
 * The vocabularies are read off the code, not invented: `DIETARY_WORDS`, `ALLERGEN_WORDS`,
 * `ATMOSPHERE_WORDS` and `CUISINE_WORDS` in `src/backend/mock.ts` (the deterministic parser,
 * which is the fullest enumeration), the tags `AIKanji/supabase/seed.sql` stores, and
 * `ATMOSPHERE_JA` in `mock.ts` for the atmosphere register. Nothing outside that is guessed:
 * an unrecognised tag prints as stored, because a dietary or allergy tag that silently
 * disappeared would be a safety problem and an invented translation is worse than the English.
 *
 * Mirrored 1:1 by `AppCopy.dietary/allergen/atmosphere/cuisine` in AppCopy.swift.
 */

/** `DIETARY_WORDS` in mock.ts; `vegetarian` is also the tag seed.sql stores on venues. */
export function dietaryLabel(value: string): string | null {
  switch (value) {
    case 'vegan':
      return 'ヴィーガン'
    case 'vegetarian':
      return 'ベジタリアン'
    case 'halal':
      return 'ハラル'
    case 'gluten_free':
      return 'グルテンフリー'
    default:
      return null
  }
}

/**
 * `ALLERGEN_WORDS` in mock.ts, labelled with the terms Japanese food labelling uses
 * (消費者庁の特定原材料: 卵・乳・小麦・そば・落花生), so the word on screen is the word on a
 * menu rather than an approximation of one.
 *
 * `shellfish` is the CRUSTACEAN member of the closed allergen vocabulary (0026) — えび and
 * かに — so 甲殻類 is exact rather than an approximation. 貝 is deliberately outside it: a
 * venue that has confirmed itself `shellfish_free` has said nothing about oysters or clams, so
 * folding molluscs in would record a weaker requirement than the participant stated. Since
 * 0026, 「貝アレルギー」 keeps the writer's wording in `semantic_remainder` and asks, rather
 * than being silently mapped here.
 */
export function allergenLabel(value: string): string | null {
  switch (value) {
    case 'shellfish':
      return '甲殻類'
    case 'egg':
      return '卵'
    case 'milk':
      return '乳'
    case 'peanut':
      return '落花生（ピーナッツ）'
    case 'wheat':
      return '小麦'
    case 'buckwheat':
      return 'そば'
    default:
      return null
  }
}

/**
 * `ATMOSPHERE_WORDS` in mock.ts. The wording is `ATMOSPHERE_JA`'s verbatim, so a tag reads the
 * same in a requirement (「雰囲気：静か」) and in a card's explanation (「静かな雰囲気」).
 */
export function atmosphereLabel(value: string): string | null {
  switch (value) {
    case 'quiet':
      return '静か'
    case 'lively':
      return '賑やか'
    case 'casual':
      return 'カジュアル'
    case 'traditional_japanese':
      return '和風'
    case 'stylish':
      return 'おしゃれ'
    default:
      return null
  }
}

/** `CUISINE_WORDS` in mock.ts — the words the parser matched, given back in Japanese. */
export function cuisineLabel(value: string): string | null {
  switch (value) {
    case 'yakitori':
      return '焼き鳥'
    case 'izakaya':
      return '居酒屋'
    case 'japanese':
      return '和食'
    case 'sushi':
      return '寿司'
    case 'yakiniku':
      return '焼肉'
    case 'ramen':
      return 'ラーメン'
    case 'italian':
      return 'イタリアン'
    case 'chinese':
      return '中華'
    case 'korean':
      return '韓国料理'
    case 'curry':
      return 'カレー'
    case 'soba':
      return 'そば'
    default:
      return null
  }
}

/**
 * Mirrors AppCopy.errorMessage(for:) — maps the RPC exception text raised by the
 * security definer functions onto a calm, non-technical Japanese message.
 */
export function errorMessage(error: unknown): string {
  const description = (error instanceof Error ? error.message : String(error ?? '')).toLowerCase()
  // Credentials first, and before the generic `invalid` branch below would swallow it:
  // GoTrue answers a wrong password with "Invalid login credentials", and telling somebody
  // 「内容を確認して、もう一度お試しください」 when the actual problem is their password is
  // unhelpful. Same order and same three probes as AppCopy.errorMessage(for:) on iOS.
  if (
    description.includes('invalid login credentials') ||
    description.includes('invalid email') ||
    description.includes('invalid password')
  ) {
    return AppCopy.invalidCredentialsError
  }
  if (
    description.includes('only the organizer') ||
    description.includes('not permitted') ||
    description.includes('permission') ||
    // What PostgREST answers when RLS refuses the write: `403 new row violates row-level
    // security policy for table "…"`. Without this probe it fell through to networkError, so
    // adding a requirement after the organizer closed collection told the participant to
    // 「時間をおいて、もう一度お試しください」 — advice that can never work, for a refusal that
    // was deliberate. The message must say it was not allowed, not that the network failed.
    description.includes('violates row-level security')
  ) {
    return AppCopy.permissionError
  }
  if (
    description.includes('unknown restaurant') ||
    description.includes('invalid') ||
    description.includes('must')
  ) {
    return AppCopy.invalidRequestError
  }
  return AppCopy.networkError
}

/* -------------------------------------------------------------------------- */
/* PRD §12 — progressive search readiness                                      */
/* -------------------------------------------------------------------------- */

/** Everyone who could answer has answered — no further input is expected. */
function isComplete(readiness: CollectionReadiness): boolean {
  return readiness.participant_count > 0 && readiness.responded_count >= readiness.participant_count
}

/** The raw shape of the progress: people, not constraint rows, plus the threshold. */
export function readinessCounts(readiness: CollectionReadiness): string {
  return `${readiness.participant_count}人中${readiness.responded_count}人が回答（目安は${readiness.threshold_count}人）`
}

/** What the current state means, in one sentence. */
export function readinessSummary(readiness: CollectionReadiness): string {
  if (readiness.preferences_closed) {
    return '希望の受付は締め切り済みです。これ以上、条件は増えません。'
  }
  if (isComplete(readiness)) {
    return '全員の回答がそろいました。'
  }
  if (readiness.threshold_met) {
    return 'おすすめを出せる人数に届きました。まだ回答していない人がいるので、結果は暫定です。'
  }
  const remaining = Math.max(readiness.threshold_count - readiness.responded_count, 0)
  return `あと${remaining}人の回答で、おすすめを出せる目安に届きます。`
}

/**
 * What the 幹事 can do about it. PRD §12 explicitly does not want the group held up by a
 * silent colleague, so searching early is offered — labelled as provisional, not blocked.
 */
export function readinessHint(readiness: CollectionReadiness): string {
  if (readiness.preferences_closed) {
    return '参加者は条件を追加・変更できません。'
  }
  if (isComplete(readiness)) {
    return '全員分の条件をもとに計算します。'
  }
  if (readiness.threshold_met) {
    return '回答が増えたら、もう一度探すと結果が変わることがあります。'
  }
  return '今すぐ探すこともできます。その場合は、いまの回答だけをもとにした暫定のおすすめになります。'
}

/** Exactly what the 幹事 is locking in, stated before they confirm the close. */
export function closeSnapshotText(readiness: CollectionReadiness): string {
  return `いま締め切ると、${readiness.participant_count}人中${readiness.responded_count}人の回答で確定します。`
}

/** 「2月3日 14:30 に締め切りました。」 — when, so "closed" is a fact and not a mood. */
export function closedAtText(closedAt: string | null): string | null {
  if (!closedAt) return null
  const at = new Date(closedAt)
  if (Number.isNaN(at.getTime())) return null
  const stamp = new Intl.DateTimeFormat('ja-JP', {
    month: 'long',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  }).format(at)
  return `${stamp} に締め切りました。`
}

/**
 * What a shortlist is actually based on. `basis` is the readiness captured when the run
 * landed, so the label describes that run rather than whatever has changed since.
 */
export function resultBasisText(basis: CollectionReadiness | null): string {
  if (!basis) {
    return '前回の計算結果を表示しています。いまの条件で確認するには、もう一度探してください。'
  }
  if (basis.preferences_closed) {
    return `締め切り後の条件（${basis.participant_count}人中${basis.responded_count}人の回答）で計算した結果です。`
  }
  if (isComplete(basis)) {
    return `全員（${basis.participant_count}人）の条件で計算した結果です。`
  }
  return `暫定：${basis.participant_count}人中${basis.responded_count}人の回答で計算した結果です。`
}

/* -------------------------------------------------------------------------- */
/* Travel-reference place picker (CreateEvent / JoinEvent)                     */
/* -------------------------------------------------------------------------- */

/**
 * `travel_reference` is a category, not a place, so the participant also picks a
 * real place for it. These strings explain that without jargon, and — because the
 * place is optional — name the consequence of skipping it, since travel fairness
 * degrades silently otherwise.
 */
export const TravelCopy = {
  sectionTitle: '移動の基準',
  sectionHelp: 'よく使う場所を選ぶと、みんなの移動の負担を公平に計算できます。',
  searchPlaceholder: '例：渋谷駅',
  searching: '探しています…',
  noResults: '見つかりませんでした。駅名や地名で試してください。',
  searchFailed: '場所を検索できませんでした。',
  change: '変更する',
  /** Shown while a location-bearing reference has no place yet. */
  missingPlace: '場所は未設定です。このまま進めますが、移動のしやすさの計算には入りません。',
  /** Shown for どこでも, which is a valid answer and needs no place. */
  unconstrained: '移動の条件は出しません。ほかの人が集まりやすい場所に合わせます。',
} as const

/* -------------------------------------------------------------------------- */
/* Changing a travel reference after joining (ConstraintEntry)                  */
/* -------------------------------------------------------------------------- */

/**
 * PRD §4 lists the travel reference under "Context — not itself a constraint;
 * changeable later", so it lives on 「あなたの希望」 next to the requirements rather than
 * being frozen at join time. These strings say what setting a place BUYS the
 * participant, because the cost of skipping it is invisible: their travel burden simply
 * never enters the fairness calculation.
 */
export const TravelEditCopy = {
  /** Opens the editor; the wording changes because setting and changing feel different. */
  set: '移動の基準を設定する',
  change: '移動の基準を変える',
  sheetTitle: '移動の基準',
  /** The benefit, stated plainly. */
  benefit: '場所を設定すると、あなたの移動の負担も「移動の公平さ」の計算に入ります。',
  save: 'この内容で保存する',
  saved: '移動の基準を保存しました。',
  /**
   * Only the place id is stored, so a place set earlier (or on the join screen) has no
   * name to show. Said plainly instead of showing an opaque provider id.
   */
  storedPlace: '設定済みの場所を使います',
  /** どこでも, chosen deliberately: the place is cleared, and that is not a loss. */
  clearsPlace: '「どこでも」を選ぶと、設定した場所は消えます。移動の条件は出さない扱いになります。',
} as const

/** 「いまの設定：駅（場所あり）」 — what is actually stored, before anything is changed. */
export function travelCurrentText(
  reference: TravelReference | null,
  placeId: string | null,
): string {
  if (reference === null) {
    return 'いまの設定：まだありません。'
  }
  if (reference === 'doesnt_matter') {
    return `いまの設定：${travelLabel(reference)}（移動の条件は出していません）`
  }
  return placeId === null
    ? `いまの設定：${travelLabel(reference)}（場所は未設定）`
    : `いまの設定：${travelLabel(reference)}（場所は設定済み）`
}

/** What the current setting means for this one person, on their own screen. */
export function travelCurrentHint(
  reference: TravelReference | null,
  placeId: string | null,
): string {
  if (reference === 'doesnt_matter') {
    return '移動の条件は出していないので、場所は必要ありません。'
  }
  return placeId === null
    ? '場所が未設定のため、あなたの移動の負担は計算に入っていません。'
    : 'あなたの移動の負担も計算に入っています。'
}

/* -------------------------------------------------------------------------- */
/* Travel-origin coverage of a search (OrganizerDashboard)                     */
/* -------------------------------------------------------------------------- */

/**
 * What a search could and could not measure, for the 幹事.
 *
 * Aggregates only, by design and by type: `TravelOriginCoverage` carries counts, never
 * participant ids, so this screen cannot name the person who skipped the place picker —
 * the same rule as 「誰がどの条件を出したかは表示せず、集計結果だけを共有します。」
 */
export const TravelGapCopy = {
  /** Heading when the search could not run at all (restaurant-search answered 422). */
  blockedTitle: '出発地が分からないため、お店を探せませんでした',
  /** Heading when the search ran, but not everyone's travel could be measured. */
  partialTitle: '移動の計算に入っていない人がいます',
  /** How the 幹事 unblocks it, without singling anybody out. */
  ask: '参加者に「あなたの希望」の画面から移動の基準を設定してもらうと、計算できるようになります。',
  /** Said out loud, because an aggregate that looks evasive gets worked around. */
  privacy: 'だれが未設定かは表示しません。人数だけをお知らせします。',
} as const

/** 「4人が場所を…」 — the count, the consequence, and nothing that identifies anyone. */
export function travelUnresolvedText(count: number): string {
  return `${count}人が移動の基準の場所を設定していません。その人の移動の負担は分からないため、移動に関する数字は全員分ではありません。`
}

/** The blocked case: not one participant has a usable origin, so nothing was searched. */
export function travelBlockedText(count: number): string {
  return count > 0
    ? `${count}人ぶんの出発地が分かりません。だれか1人でも場所を設定すると、お店を探せるようになります。`
    : '出発地が分かる人がいません。だれか1人でも場所を設定すると、お店を探せるようになります。'
}

/**
 * どこでも is a valid answer, not a gap: stated separately and neutrally so a
 * participant who opted out of travel constraints is never counted as a problem.
 */
export function travelUnconstrainedText(count: number): string {
  return `「どこでも」と答えた人が${count}人います。移動の条件を出していないので、これは問題ではありません。`
}

/** Label for the place field, phrased for the reference the participant chose. */
export function travelPlaceLabel(reference: TravelReference): string {
  switch (reference) {
    case 'office':
      return '会社の場所'
    case 'home':
      return '自宅の最寄り駅'
    case 'station':
      return '出発する駅'
    case 'doesnt_matter':
      return '場所'
  }
}

/* -------------------------------------------------------------------------- */
/* Recommendation score breakdown (PRD §9)                                     */
/* -------------------------------------------------------------------------- */

/**
 * Web-only additions: the iOS card only carries a badge, but PRD §9 forbids presenting
 * one opaque universal score, so the web card names every dimension, the emphasis the
 * 幹事's objective put on it, and — separately — whether the underlying data exists.
 */
export const ScoreCopy = {
  showDetail: '内訳を見る',
  hideDetail: '内訳を閉じる',
  /** Shown instead of a percentage when the stored number is a missing-data placeholder. */
  unknown: '未確認',
  /**
   * The two polarities on one screen: components are higher-better, burdens are
   * higher-worse. Said plainly so a bar is never misread.
   */
  scaleNote:
    'バーは、長いほど良い項目です。予算と設備は「負担」も書いていますが、負担は数字が大きいほど、だれかの負担が重いという意味です。',
  legendNote:
    '● はこの会で重視した項目です。データがそろっていない項目は「未確認」と出します。評価が低いという意味ではありません。',
  weightedTotal: '重み付け合計',
  weightedTotalNote: 'この6項目に、この会の重みをかけて足した値です（0〜1）。',
  detailAriaLabel: 'スコアの内訳',
} as const

export function scoreDimensionLabel(dimension: ScoreDimension): string {
  switch (dimension) {
    case 'travel_fairness':
      return '移動の公平さ'
    case 'travel_access':
      return '移動の近さ'
    case 'satisfaction':
      return 'みんなの希望'
    case 'quality':
      return 'お店の評価'
    case 'cost_fit':
      // Deliberately not 「安さ」: the component is 1 - price/tightest budget, i.e. how much
      // headroom is left against the tightest budget in the group, so ゆとり and the 負担
      // spelled out in the detail add up to 100% and the polarity reads for itself.
      return '予算のゆとり'
    case 'accessibility_fit':
      return '設備への配慮'
  }
}

/** 0..1 → 「82%」. Clamped, because a stored value is trusted but never assumed in range. */
export function scorePercent(value: number): string {
  return `${Math.round(Math.min(1, Math.max(0, value)) * 100)}%`
}

/**
 * Which dimensions this event's objective actually leans on: the ones weighted above an
 * even split. `fn_objective_weights` always has a peak, so this never comes back empty.
 */
export function emphasizedScoreDimensions(weights: ObjectiveWeights): ScoreDimension[] {
  const evenShare = 1 / SCORE_DIMENSIONS.length
  const above = SCORE_DIMENSIONS.filter((dimension) => weights[dimension] > evenShare)
  const chosen =
    above.length > 0
      ? above
      : SCORE_DIMENSIONS.filter(
          (dimension) =>
            weights[dimension] === Math.max(...SCORE_DIMENSIONS.map((key) => weights[key])),
        )
  return [...chosen].sort((a, b) => weights[b] - weights[a])
}

export function objectiveEmphasisText(breakdown: ScoreBreakdown): string {
  const emphasized = emphasizedScoreDimensions(breakdown.weights)
    .map(scoreDimensionLabel)
    .join('・')
  return `この会の目的は「${objectiveLabel(breakdown.objective)}」。${emphasized}を重めに見て並べています。`
}

/**
 * True when the stored number is a placeholder for data we never got, not a measurement.
 * `fn_banded_score` keeps those below 0.2 so they cannot outrank measured data, which
 * means showing them as a plain low percentage would read as "this venue is bad".
 */
export function isScoreDimensionUnknown(
  breakdown: ScoreBreakdown,
  dimension: ScoreDimension,
): boolean {
  switch (dimension) {
    case 'travel_fairness':
    case 'travel_access':
      return !breakdown.travel.complete || breakdown.travel.known === 0
    case 'quality':
      return breakdown.quality.method === 'atmosphere_tag_proxy'
    case 'cost_fit':
      // An unknown price is scored as the worst case, so it is a gap, not a measurement.
      return breakdown.cost.price_yen === null
    case 'accessibility_fit':
      // With no request there is nothing to verify; the gap only matters if someone asked.
      return !breakdown.accessibility.data_present && breakdown.accessibility.requests > 0
    case 'satisfaction':
      return false
  }
}

function accessibilityNeedLabel(need: string): string {
  switch (need) {
    // The controlled vocabulary from 0022, named 1:1 after the Google Places
    // accessibilityOptions booleans it is recorded from.
    case 'wheelchair_accessible_entrance':
      return '車椅子で入れる入口'
    case 'wheelchair_accessible_restroom':
      return '車椅子で使えるトイレ'
    case 'wheelchair_accessible_seating':
      return '車椅子で座れる席'
    case 'wheelchair_accessible_parking':
      return '車椅子で使える駐車場'
    // Pre-0022 wording, kept so a constraint stored before the backfill still reads in
    // Japanese rather than showing a raw tag.
    case 'wheelchair':
      return '車椅子対応'
    case 'step_free':
      return '段差なし'
    case 'elevator':
      return 'エレベーター'
    default:
      return need
  }
}

function needList(needs: string[]): string {
  return needs.map(accessibilityNeedLabel).join('・')
}

/** One sentence per dimension, grounded in the stored breakdown (acceptance test A7). */
export function scoreDimensionEvidence(
  breakdown: ScoreBreakdown,
  dimension: ScoreDimension,
): string {
  const { travel, quality, cost, accessibility } = breakdown
  const average = travel.average_minutes === null ? null : Math.round(travel.average_minutes)

  switch (dimension) {
    case 'travel_fairness':
      if (isScoreDimensionUnknown(breakdown, dimension)) {
        return `移動時間が分かっているのは${travel.participants}人中${travel.known}人です。負担の差はまだ比べられません。`
      }
      if (travel.known < 2) {
        return `移動時間が分かっているのは${travel.known}人分なので、差は生じていません。`
      }
      return `いちばん近い人といちばん遠い人の差は${Math.round(travel.spread_minutes)}分です。`
    case 'travel_access':
      if (isScoreDimensionUnknown(breakdown, dimension) || average === null) {
        return `平均の移動時間は、${travel.participants}人中${travel.known}人分しか分かっていません。`
      }
      return `${travel.participants}人の平均の移動時間は約${average}分です。`
    case 'satisfaction':
      return `みんなの「できれば欲しい」に、${scorePercent(breakdown.components.satisfaction)}ほど合っています。`
    case 'quality':
      if (quality.method === 'atmosphere_tag_proxy') {
        return `口コミ評価が取れていないため、雰囲気タグ${quality.atmosphere_tags}件からの暫定値です。低い評価という意味ではありません。`
      }
      return `口コミ${quality.rating}（${quality.user_rating_count}件）をもとに、件数の少なさを補正して見ています。`
    case 'cost_fit':
      if (cost.price_yen === null) {
        return `価格が取れていないため、負担${scorePercent(cost.burden)}のいちばん厳しい見立てにしています。`
      }
      if (cost.tightest_budget_yen !== null) {
        return `1人${cost.price_yen}円。いちばん厳しい予算${cost.tightest_budget_yen}円に対して、負担は${scorePercent(cost.burden)}です。`
      }
      return `1人${cost.price_yen}円。予算の希望がないため、目安の${cost.reference_yen}円に対して負担は${scorePercent(cost.burden)}です。`
    case 'accessibility_fit':
      if (accessibility.requests === 0) {
        return '設備についての希望は出ていません。'
      }
      if (!accessibility.data_present) {
        return `お店の設備情報が取れていないため、希望${accessibility.needs.length}件（${needList(accessibility.needs)}）を確認できていません。`
      }
      if (accessibility.unmet_needs.length > 0) {
        return `希望${accessibility.needs.length}件のうち${accessibility.unmet_needs.length}件（${needList(accessibility.unmet_needs)}）が未対応で、負担は${scorePercent(accessibility.burden)}です。`
      }
      return `希望された設備（${needList(accessibility.needs)}）に対応しています。`
  }
}

/**
 * The one-line "what we could not check" summary. Named by source rather than by
 * dimension, because one missing travel matrix darkens two dimensions at once.
 */
export function scoreDataGapNote(breakdown: ScoreBreakdown): string | null {
  const missing: string[] = []
  if (!breakdown.travel.complete || breakdown.travel.known === 0) {
    missing.push(`移動時間（${breakdown.travel.participants}人中${breakdown.travel.known}人分）`)
  }
  if (breakdown.quality.method === 'atmosphere_tag_proxy') missing.push('口コミ評価')
  if (breakdown.cost.price_yen === null) missing.push('価格')
  if (!breakdown.accessibility.data_present && breakdown.accessibility.requests > 0) {
    missing.push('設備情報')
  }
  if (missing.length === 0) return null
  return `未取得：${missing.join('・')}。データがないだけで、低い評価という意味ではありません。`
}

/* -------------------------------------------------------------------------- */
/* Provider attribution (licence obligation, not a feature)                    */
/* -------------------------------------------------------------------------- */

/**
 * Recruit's Hot Pepper Gourmet Web Service usage guideline
 * (https://webservice.recruit.co.jp/doc/hotpepper/guideline.html) makes a visible credit
 * mandatory for any site or app that uses the data: either the supplied banner or the text
 * 「Powered by ホットペッパーグルメ Webサービス」, linked to Hot Pepper Gourmet. So `credit`
 * is their required wording verbatim — it is not ours to reword or shorten.
 *
 * `scope` exists because only part of a listing comes from them: `restaurant-search`
 * discovers venues through Google Places (name, location, rating) and merges Hot Pepper's
 * 個室 availability and yen budget band onto the match. Printing the credit alone would
 * claim the whole shortlist as theirs, so the sentence above it says which two fields are
 * actually sourced there.
 *
 * Google's Maps/Places terms carry their own, different attribution requirements for
 * Places content, which the Hot Pepper credit does not discharge. The `google*` entries below
 * are that separate credit; see web/README.md for what is and is not covered.
 *
 * Mirrors `AttributionCopy` in AIKanji/AIKanji/DesignSystem/AppCopy.swift.
 */
export const AttributionCopy = {
  scope:
    '個室の有無と予算の目安は、ホットペッパーグルメ Webサービスの情報です。お店の場所や口コミ評価など、ほかの情報は別の提供元から取得しています。',
  /** Recruit's mandated credit wording. Do not translate, abbreviate or hide it. */
  credit: 'Powered by ホットペッパーグルメ Webサービス',
  href: 'https://www.hotpepper.jp/',

  /**
   * Google's Places policy requires Google Maps attribution wherever Places content is shown
   * *without* a Google map — exactly this screen: a list of venues, no map. `scope` above
   * already says which two fields are Hot Pepper's, so this names the other side rather than
   * leaving 「別の提供元」 anonymous: `restaurant-search` finds the candidates through Places
   * and stores the Places `displayName`, location and `rating`/`userRatingCount`.
   */
  googleScope:
    'お店探しと、店名・場所・口コミ評価（評価の件数を含む）などのお店の情報は、Google Maps から取得しています。',
  /**
   * The sanctioned text form of the attribution, which the policy allows in place of the logo
   * where space is limited. Deliberately NOT a bundled logo image: Google's brand rules govern
   * the asset, its clear space and its colour variants, and none of that can be verified from
   * here — shipping a wrong or stale logo would be a worse violation than the text form they
   * sanction. Latin script, unmodified: it is Google's mark, not a phrase to translate,
   * abbreviate or fold into the sentence above.
   */
  googleCredit: 'Google Maps',
} as const
