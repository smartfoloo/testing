/**
 * Ported from the `displayText` / `ConstraintFormatter` extensions in
 * Models/Constraint.swift and the `question` / `impact` computed properties in
 * Models/Negotiation.swift.
 */

import { AppCopy, normalizedTypeLabel, roomLabel } from '../design/copy'
import type {
  FeedItem,
  JSONValue,
  NormalizedType,
  NormalizedValue,
  PendingNegotiation,
} from './types'

export function displayText(value: JSONValue | undefined): string {
  if (value === undefined || value === null) return '—'
  if (typeof value === 'string') return value
  if (typeof value === 'number') return Number.isInteger(value) ? String(value) : String(value)
  if (typeof value === 'boolean') return value ? 'はい' : 'いいえ'
  if (Array.isArray(value)) return value.map(displayText).join(', ')
  return Object.entries(value)
    .map(([key, nested]) => `${key}: ${displayText(nested)}`)
    .join(', ')
}

/** Optional lookup that returns undefined for absent keys so callers can fall through. */
function text(value: NormalizedValue, key: string): string | undefined {
  const raw = value[key]
  if (raw === undefined) return undefined
  const rendered = displayText(raw)
  return rendered.length > 0 ? rendered : undefined
}

export function constraintSummary(type: NormalizedType, value: NormalizedValue): string {
  const label = normalizedTypeLabel(type)
  if (Object.keys(value).length === 0) return label

  switch (type) {
    case 'room': {
      const room = text(value, 'room')
      const named = room ? roomLabel(room) : null
      if (named) return `${label}：${named}`
      break
    }
    case 'budget': {
      const amount = text(value, 'max_yen')
      if (amount) return `${label}：${amount}円まで`
      break
    }
    case 'travel_time': {
      const minutes = text(value, 'max_minutes')
      if (minutes) return `${label}：${minutes}分以内`
      break
    }
    case 'cuisine': {
      const include = text(value, 'include')
      if (include) return `${label}：${include}`
      break
    }
    case 'dietary':
    case 'atmosphere': {
      const tags = text(value, 'tags')
      if (tags) return `${label}：${tags}`
      break
    }
    case 'allergy': {
      const allergens = text(value, 'allergens')
      if (allergens) return `${label}：${allergens}`
      break
    }
    default:
      break
  }

  return `${label}：${Object.values(value).map(displayText).join('、')}`
}

export function feedLine(item: FeedItem): string {
  const who = item.display_name ?? '匿名の参加者'
  const prefix = item.kind === 'MUST' ? AppCopy.must : AppCopy.want
  return `${who}｜${prefix}：${constraintSummary(item.normalized_type, item.normalized_value)}`
}

export function negotiationQuestion(negotiation: PendingNegotiation): string {
  const constraint = negotiation.participant_constraints
  switch (constraint.normalized_type) {
    case 'room': {
      const proposedRaw = text(negotiation.proposed_value, 'room')
      const currentRaw = text(constraint.normalized_value, 'room')
      const proposed = (proposedRaw ? roomLabel(proposedRaw) : null) ?? '別の席'
      const current = (currentRaw ? roomLabel(currentRaw) : null) ?? '今の条件'
      return `${current}を${proposed}に変更しても大丈夫ですか？`
    }
    case 'travel_time': {
      const proposed = text(negotiation.proposed_value, 'max_minutes') ?? '少し長い'
      return `移動時間を${proposed}分以内に変更しても大丈夫ですか？`
    }
    case 'budget': {
      const proposed = text(negotiation.proposed_value, 'max_yen') ?? '少し高い'
      return `予算を${proposed}円まで変更しても大丈夫ですか？`
    }
    default:
      return `${constraintSummary(constraint.normalized_type, negotiation.proposed_value)}に変更しても大丈夫ですか？`
  }
}

export function negotiationImpact(negotiation: PendingNegotiation): string {
  return `${negotiation.unlocked_count}件のお店が候補に加わります。`
}

export function roomDescription(roomType: string | null): string | null {
  return roomType ? roomLabel(roomType) : null
}
