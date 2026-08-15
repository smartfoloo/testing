/**
 * Ported 1:1 from AIKanji/AIKanji/DesignSystem/AppCopy.swift.
 * The app is Japanese-only, so these strings are the product surface — keep them verbatim.
 */

import type {
  ConstraintKind,
  ConstraintVisibility,
  EventObjective,
  NormalizedType,
  RecommendationLabel,
  TravelReference,
} from '../models/types'

export const AppCopy = {
  appName: 'まとメシ',
  tagline: 'みんなの条件から、ちょうどいい店を。',
  create: 'お店選びをはじめる',
  join: '招待コードで参加',
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
  invalidRequestError:
    'この操作は完了できませんでした。内容を確認して、もう一度お試しください。',
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

/**
 * Mirrors AppCopy.errorMessage(for:) — maps the RPC exception text raised by the
 * security definer functions onto a calm, non-technical Japanese message.
 */
export function errorMessage(error: unknown): string {
  const description = (error instanceof Error ? error.message : String(error ?? '')).toLowerCase()
  if (
    description.includes('only the organizer') ||
    description.includes('not permitted') ||
    description.includes('permission')
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
