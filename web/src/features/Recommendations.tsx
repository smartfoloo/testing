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
 */
function ProviderAttribution() {
  return (
    <div data-testid="provider-attribution" className="flex flex-col gap-xxs">
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

      {scores.length > 0 && <ProviderAttribution />}
    </div>
  )
}
