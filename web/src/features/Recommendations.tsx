/** Ported from Features/Recommendations/RecommendationListView.swift (view + view model). */

import { useCallback, useEffect, useState } from 'react'
import { useBackend } from '../backend'
import {
  AppCopy,
  AttributionCopy,
  ScoreCopy,
  errorMessage as toMessage,
  objectiveEmphasisText,
} from '../design/copy'
import { EmptyStateView, InlineErrorView, LoadingStateView } from '../design/components'
import { RecommendationCard } from './RecommendationCard'
import type {
  EventDecision,
  RecommendationScore,
  RestaurantFeature,
  ScoreBreakdown,
} from '../models/types'

/**
 * PRD §9: the 幹事's objective changes the emphasis, not the feasibility. Saying that once
 * above the list keeps every card free to spend its space on its own numbers, and gives the
 * per-card 「重視」 dots and 「未確認」 marks a single place to be explained.
 */
function ObjectiveLegend({ breakdown }: { breakdown: ScoreBreakdown }) {
  return (
    <div
      data-testid="score-legend"
      className="flex flex-col gap-xxs rounded-card bg-green-soft px-md py-sm"
    >
      <p data-testid="score-emphasis" className="text-caption font-semibold">
        {objectiveEmphasisText(breakdown)}
      </p>
      <p className="text-small text-ink/72">{ScoreCopy.legendNote}</p>
    </div>
  )
}

/**
 * Recruit's Hot Pepper Gourmet Web Service guideline requires this credit wherever their
 * data is used, so it lives at the foot of the shortlist — the one screen that prints the
 * fields we merge from them (the yen band and the 個室 line on every card). It is not a
 * feature: muted secondary caption, below the content, never above 「このお店に決める」.
 *
 * One credit for the whole list, not one per card. The chosen card is the same
 * `RecommendationCard` with 「このお店に決まりました」 swapped in for the button, and it stays
 * inside this list, so it is already covered — repeating the credit three or four times
 * would be louder than the guideline asks and would compete with the decision itself.
 * (The 「決まりました」 banner on EventHome and the organizer dashboard show only a name the
 * group chose, which is the group's own decision rather than a Hot Pepper listing.)
 *
 * Not rendered when the list is empty: with no venue attributes on screen there is nothing
 * sourced to credit.
 *
 * Two credits, because two providers impose obligations and neither discharges the other's.
 * Each keeps its own scope sentence so neither over-claims: Hot Pepper supplies 個室 and the
 * yen band, Places supplies the discovery itself plus the name, location and rating/review
 * count. Google's Places policy requires Google Maps attribution wherever Places content is
 * displayed without a Google map, which is exactly this screen.
 */
/**
 * One displayable line per stored credit. Elements arrive verbatim in either of the two shapes
 * the column accepts, so this selects the text to show and never rewrites it:
 *
 *   string  — the historical HTML-ish form, shown as given.
 *   object  — Places (New) documents a provider name plus a provider URI; the NAME is the
 *             credit, so a string `provider` is used and nothing is synthesised from the URI.
 *
 * Anything else (a number, a nested array, an object with no usable name) is DROPPED rather
 * than stringified, because `[object Object]` in a licence credit is worse than a missing one
 * — and dropping is visible in the count, whereas a mangled credit looks deliberate. Duplicates
 * are collapsed so one provider is credited once per card.
 */
function attributionLines(stored: unknown[] | null | undefined): string[] {
  if (!Array.isArray(stored)) return []
  const lines = stored.flatMap((entry) => {
    if (typeof entry === 'string') return entry.trim() ? [entry.trim()] : []
    if (entry && typeof entry === 'object' && !Array.isArray(entry)) {
      const provider = (entry as { provider?: unknown }).provider
      if (typeof provider === 'string' && provider.trim()) return [provider.trim()]
    }
    return []
  })
  return [...new Set(lines)]
}

function ProviderAttribution({
  /**
   * The per-place third-party attributions Places returns, already reduced to display-ready
   * lines by whatever owns the type. The policy says they must be displayed with the content
   * they belong to, so they render inside the same block as the credit.
   *
   * TODO(B5): nothing can pass these yet, so they are never shown. The storage half exists —
   * `restaurant_features.provider_attributions` (jsonb, migration 0023), written by
   * `fn_record_provider_attributions` from the `places.attributions` the search requests, and
   * `attributionLines()` below turns each stored element into one displayable line.
   */
  placeAttributions = [],
}: {
  placeAttributions?: string[]
}) {
  return (
    <div data-testid="provider-attribution" className="flex flex-col gap-sm">
      <div className="flex flex-col gap-xxs">
        <p className="text-small text-ink/72">{AttributionCopy.scope}</p>
        <p>
          <a
            href={AttributionCopy.href}
            target="_blank"
            rel="noopener noreferrer"
            data-testid="provider-attribution-link"
            className="inline-flex min-h-[44px] items-center text-caption text-ink/72 underline underline-offset-2"
          >
            {AttributionCopy.credit}
          </a>
        </p>
      </div>

      <div data-testid="google-attribution" className="flex flex-col gap-xxs">
        <p className="text-small text-ink/72">{AttributionCopy.googleScope}</p>
        {/*
          The text form of the attribution, not a hosted logo asset: Google's brand rules
          govern the image, and a wrong or stale logo would be a worse violation than the text
          form their policy sanctions where space is limited. Unmodified and at full ink
          contrast rather than the /72 used for our own footnotes, because the policy requires
          it to stay legible — and not a link, since the policy asks for the attribution
          itself, and inventing a destination for Google's mark would imply more than it says.
        */}
        <p data-testid="google-attribution-credit" className="text-caption text-ink">
          {AttributionCopy.googleCredit}
        </p>
        {placeAttributions.length > 0 && (
          <ul data-testid="place-attributions" className="flex flex-col gap-xxs">
            {placeAttributions.map((attribution) => (
              // Rendered as text, verbatim. These strings are HTML-ish, and
              // `dangerouslySetInnerHTML` on third-party content is not an option here, so
              // the characters are preserved exactly as given rather than interpreted.
              <li key={attribution} className="text-small text-ink/72">
                {attribution}
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  )
}

interface RecommendationsProps {
  runId: string
  eventId: string
  isOrganizer: boolean
  decision: EventDecision | null
  onChosen: (decision: EventDecision) => void
}

export function Recommendations({
  runId,
  eventId,
  isOrganizer,
  decision,
  onChosen,
}: RecommendationsProps) {
  const backend = useBackend()
  const [scores, setScores] = useState<RecommendationScore[]>([])
  const [features, setFeatures] = useState<Record<string, RestaurantFeature>>({})
  const [explanations, setExplanations] = useState<Record<string, string>>({})
  const [explaining, setExplaining] = useState<Set<string>>(new Set())
  const [isLoading, setIsLoading] = useState(false)
  const [errorMessage, setErrorMessage] = useState<string | null>(null)
  const [isChoosing, setIsChoosing] = useState(false)
  const [choiceError, setChoiceError] = useState<string | null>(null)

  const load = useCallback(async () => {
    setIsLoading(true)
    setErrorMessage(null)
    try {
      const loadedScores = await backend.scores(runId)
      setScores(loadedScores)

      // An explanation already stored on the row wins; only the gaps are generated.
      const stored: Record<string, string> = {}
      for (const score of loadedScores) {
        const trimmed = score.explanation?.trim()
        if (trimmed) stored[score.restaurant_place_id] = trimmed
      }
      setExplanations((current) => ({ ...stored, ...current }))

      const loadedFeatures = await backend.features(
        loadedScores.map((score) => score.restaurant_place_id),
      )
      setFeatures(Object.fromEntries(loadedFeatures.map((feature) => [feature.place_id, feature])))
    } catch {
      setErrorMessage(AppCopy.networkError)
    }
    setIsLoading(false)
  }, [backend, runId])

  useEffect(() => {
    void load()
  }, [load])

  // Generate the missing explanations once the scores are known.
  useEffect(() => {
    for (const score of scores) {
      const placeId = score.restaurant_place_id
      if (explanations[placeId] !== undefined || explaining.has(placeId)) continue

      setExplaining((current) => new Set(current).add(placeId))
      void (async () => {
        let value: string
        try {
          value = (await backend.explanation(runId, placeId)).trim()
          if (value.length === 0) value = AppCopy.fallbackExplanation
        } catch {
          value = AppCopy.fallbackExplanation
        }
        setExplanations((current) => ({ ...current, [placeId]: value }))
        setExplaining((current) => {
          const next = new Set(current)
          next.delete(placeId)
          return next
        })
      })()
    }
  }, [backend, runId, scores, explanations, explaining])

  const choose = async (score: RecommendationScore) => {
    if (isChoosing) return
    setIsChoosing(true)
    setChoiceError(null)
    try {
      onChosen(await backend.chooseRestaurant(eventId, score.restaurant_place_id))
    } catch (error) {
      setChoiceError(toMessage(error))
    }
    setIsChoosing(false)
  }

  // Every row of a run shares the objective, so the first stored breakdown speaks for the list.
  const legendBreakdown = scores.find((score) => score.score_breakdown)?.score_breakdown ?? null

  return (
    <div className="safe-b flex flex-col gap-lg px-lg pb-xxl pt-md">
      {isLoading && scores.length === 0 && (
        <LoadingStateView title="おすすめのお店を読み込んでいます" />
      )}

      {!isLoading && scores.length === 0 && (
        <EmptyStateView
          title={AppCopy.noResults}
          message="条件を少し見直すと、候補が増えるかもしれません。"
        />
      )}

      {legendBreakdown && <ObjectiveLegend breakdown={legendBreakdown} />}

      {scores.map((score) => (
        <RecommendationCard
          key={score.id}
          score={score}
          feature={features[score.restaurant_place_id]}
          explanation={explanations[score.restaurant_place_id]}
          isExplaining={explaining.has(score.restaurant_place_id)}
          isOrganizer={isOrganizer}
          isChosen={decision?.chosen_place_id === score.restaurant_place_id}
          isChoosing={isChoosing}
          onChoose={() => void choose(score)}
        />
      ))}

      {choiceError && <InlineErrorView message={choiceError} onRetry={() => setChoiceError(null)} />}
      {errorMessage && <InlineErrorView message={errorMessage} onRetry={() => void load()} />}

      {scores.length > 0 && (
        <ProviderAttribution
          // Every credit carried by any venue currently on screen: the obligation attaches to
          // the content shown, and the shortlist shows all of them together.
          placeAttributions={[
            ...new Set(
              scores.flatMap((score) =>
                attributionLines(features[score.restaurant_place_id]?.provider_attributions),
              ),
            ),
          ]}
        />
      )}
    </div>
  )
}
