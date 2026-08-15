/**
 * Ported from the `displayText` / `ConstraintFormatter` extensions in
 * Models/Constraint.swift and the `question` / `impact` computed properties in
 * Models/Negotiation.swift.
 */

import {
  AppCopy,
  allergenLabel,
  atmosphereLabel,
  cuisineLabel,
  dietaryLabel,
  normalizedTypeLabel,
  roomLabel,
  smokingLabel,
} from '../design/copy'
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

/**
 * The members of a tag-style value, kept separate so each can be labelled on its own — the
 * whole-array `text()` above would hand back one 「quiet, lively」 string. A single stored
 * string counts as a one-member list; an empty list is undefined, which is what the callers
 * already treat as "nothing stated".
 */
function tagList(value: NormalizedValue, key: string): string[] | undefined {
  const raw = value[key]
  if (raw === undefined || raw === null) return undefined
  const items = (Array.isArray(raw) ? raw : [raw])
    .map((item) => displayText(item).trim())
    .filter((item) => item.length > 0)
  return items.length > 0 ? items : undefined
}

/**
 * Japanese labels for a tag list, falling back to the tag exactly as stored when the
 * vocabulary does not know it. Unknown tags are printed, never dropped and never guessed at:
 * an allergy or dietary tag that vanished would be a safety problem, and an invented
 * translation would be worse than the English.
 */
function labelTags(tags: string[], label: (tag: string) => string | null): string {
  return tags.map((tag) => label(tag) ?? tag).join('・')
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
      const include = tagList(value, 'include')
      if (include) return `${label}：${labelTags(include, cuisineLabel)}`
      break
    }
    case 'smoking': {
      const preference = text(value, 'preference')
      const named = preference ? smokingLabel(preference) : null
      if (named) {
        // 0021 relaxes a smoking MUST by accepting venues whose policy is unconfirmed,
        // rather than by trading away the preference itself.
        return value.accept_unknown === true
          ? `${label}：${named}（未確認のお店も可）`
          : `${label}：${named}`
      }
      break
    }
    // dietary and atmosphere share the `{"tags": []}` shape but not the vocabulary, so they
    // no longer share a branch.
    case 'dietary': {
      const tags = tagList(value, 'tags')
      if (tags) return `${label}：${labelTags(tags, dietaryLabel)}`
      break
    }
    case 'atmosphere': {
      const tags = tagList(value, 'tags')
      if (tags) return `${label}：${labelTags(tags, atmosphereLabel)}`
      break
    }
    case 'allergy': {
      const allergens = tagList(value, 'allergens')
      if (allergens) return `${label}：${labelTags(allergens, allergenLabel)}`
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
      // 0022 made the room step composite: it widens 個室 → 半個室 AND accepts venues whose
      // room type no provider could confirm. Consent has to describe BOTH concessions —
      // asking someone to agree to something the question did not mention is exactly the
      // failure this negotiation flow exists to prevent. The two parts are shown separately
      // so a widening with nothing to confirm still reads as one plain change.
      const proposedRaw = text(negotiation.proposed_value, 'room')
      const currentRaw = text(constraint.normalized_value, 'room')
      const proposed = (proposedRaw ? roomLabel(proposedRaw) : null) ?? '別の席'
      const current = (currentRaw ? roomLabel(currentRaw) : null) ?? '今の条件'
      const widened = proposedRaw !== null && currentRaw !== null && proposedRaw !== currentRaw
      const acceptsUnknown = negotiation.proposed_value.accept_unknown === true
      if (widened && acceptsUnknown) {
        return `${current}を${proposed}に変更し、席のタイプが確認できていないお店も候補に含めてよいですか？`
      }
      if (acceptsUnknown) {
        return `${current}かどうか確認できていないお店も、候補に含めてよいですか？`
      }
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
    case 'smoking': {
      // The relaxation never gives up the preference; it accepts venues whose smoking
      // policy no provider could confirm. Ask for exactly that, and say what it costs.
      const current = text(constraint.normalized_value, 'preference')
      const named = (current ? smokingLabel(current) : null) ?? '喫煙の条件'
      return `${named}かどうか確認できていないお店も、候補に含めてよいですか？`
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
