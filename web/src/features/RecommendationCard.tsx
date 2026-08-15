/**
 * Ported from Features/Recommendations/RecommendationCardView.swift, plus the PRD §9
 * score breakdown the iOS card does not have yet: "do not present one opaque universal
 * AI score". Every dimension is shown separately, with the emphasis this event's
 * objective put on it and an explicit mark when the data behind it is missing.
 */

import { useId, useState } from 'react'
import {
  AppCopy,
  ScoreCopy,
  cuisineLabel,
  emphasizedScoreDimensions,
  isScoreDimensionUnknown,
  recommendationBadge,
  recommendationText,
  scoreDataGapNote,
  scoreDimensionEvidence,
  scoreDimensionLabel,
  scorePercent,
} from '../design/copy'
import { AppCard, PrimaryButton } from '../design/components'
import {
  CheckIcon,
  ChevronLeftIcon,
  ExclamationCircleIcon,
  ForkKnifeIcon,
  Spinner,
} from '../design/icons'
import { cn } from '../design/cn'
import { roomDescription } from '../models/format'
import { SCORE_DIMENSIONS } from '../models/types'
import type {
  RecommendationScore,
  RestaurantFeature,
  ScoreBreakdown,
  ScoreDimension,
} from '../models/types'

/**
 * One row of the breakdown, already normalized so the view never has to think about
 * polarity: `value` is always higher-is-better. The burdens the engine stores
 * (cost, accessibility) reach the view as their `*_fit` component and are only ever
 * spoken about as 負担 in the prose, never drawn as a bar.
 */
interface DimensionReading {
  dimension: ScoreDimension
  /** 0..1, higher is better. Meaningless when `isUnknown`. */
  value: number
  /** The stored number is a missing-data placeholder (banded < 0.2), not a measurement. */
  isUnknown: boolean
  isEmphasized: boolean
  weight: number | null
  contribution: number | null
  evidence: string | null
}

/** Only finite stored numbers are rendered; anything else is a gap, not a zero. */
function numberOrNull(value: number | undefined): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

function readingsFromBreakdown(breakdown: ScoreBreakdown): DimensionReading[] {
  const emphasized = new Set(emphasizedScoreDimensions(breakdown.weights))
  return SCORE_DIMENSIONS.map((dimension) => {
    // A breakdown written by a newer version could omit a dimension this build knows about.
    const component = numberOrNull(breakdown.components[dimension])
    return {
      dimension,
      value: component ?? 0,
      isUnknown: component === null || isScoreDimensionUnknown(breakdown, dimension),
      isEmphasized: emphasized.has(dimension),
      weight: numberOrNull(breakdown.weights[dimension]),
      contribution: numberOrNull(breakdown.contributions[dimension]),
      evidence: scoreDimensionEvidence(breakdown, dimension),
    }
  })
}

/**
 * Fallback for rows written before 0016, which carry the flat columns but no breakdown.
 * The dimensions those columns do cover are still shown — the rest is marked 未確認
 * rather than drawn as a zero, and the weights are simply unknown.
 */
function readingsFromFlatScore(score: RecommendationScore): DimensionReading[] {
  const fit = (burden: number | null) => (burden === null ? null : 1 - burden)
  const values: Record<ScoreDimension, number | null> = {
    travel_fairness: score.fairness_score,
    travel_access: null,
    satisfaction: score.satisfaction_score,
    quality: score.quality_score,
    cost_fit: fit(score.cost_burden_score),
    accessibility_fit: fit(score.accessibility_burden_score),
  }
  return SCORE_DIMENSIONS.map((dimension) => ({
    dimension,
    value: values[dimension] ?? 0,
    isUnknown: values[dimension] === null,
    isEmphasized: false,
    weight: null,
    contribution: null,
    evidence: null,
  }))
}

/** The 「この会で重視した項目」 marker, explained once in the list legend. */
function EmphasisDot() {
  return <span className="size-[6px] shrink-0 rounded-pill bg-accent" aria-hidden="true" />
}

function DimensionMeter({ reading }: { reading: DimensionReading }) {
  // Missing data gets an empty dashed track, never a short filled bar: the banded value
  // behind it says "we do not know", not "this venue scores badly".
  if (reading.isUnknown) {
    return (
      <div
        className="h-[8px] w-full rounded-pill border border-dashed border-border"
        aria-hidden="true"
      />
    )
  }
  return (
    <div className="h-[8px] w-full overflow-hidden rounded-pill bg-ink/8" aria-hidden="true">
      <div className="h-full rounded-pill bg-accent" style={{ width: scorePercent(reading.value) }} />
    </div>
  )
}

function DimensionCell({ reading }: { reading: DimensionReading }) {
  return (
    <div data-testid={`dimension-${reading.dimension}`} className="flex flex-col gap-xxs">
      <div className="flex items-center justify-between gap-xxs">
        <span className="flex min-w-0 items-center gap-xxs">
          {reading.isEmphasized && <EmphasisDot />}
          <span
            className={cn(
              'truncate text-small',
              reading.isEmphasized ? 'font-semibold text-ink' : 'text-ink/72',
            )}
          >
            {scoreDimensionLabel(reading.dimension)}
          </span>
        </span>
        <span
          data-testid={`dimension-value-${reading.dimension}`}
          className={cn(
            'shrink-0 text-small',
            reading.isUnknown ? 'text-ink/72' : 'font-semibold text-ink',
          )}
        >
          {reading.isUnknown ? ScoreCopy.unknown : scorePercent(reading.value)}
        </span>
      </div>
      <DimensionMeter reading={reading} />
    </div>
  )
}

interface ScoreBreakdownViewProps {
  readings: DimensionReading[]
  gapNote: string | null
  /** Null for legacy rows: without stored weights there is no arithmetic to expand into. */
  objectiveScore: number | null
}

/**
 * Progressive disclosure: the six meters stay visible so two cards can be compared at a
 * glance, and the arithmetic plus the evidence sentences are one tap away.
 */
function ScoreBreakdownView({ readings, gapNote, objectiveScore }: ScoreBreakdownViewProps) {
  const [isExpanded, setIsExpanded] = useState(false)
  const detailId = useId()

  return (
    <div data-testid="score-breakdown" className="flex flex-col gap-xs rounded-card bg-background p-sm">
      <div className="grid grid-cols-2 gap-x-sm gap-y-xs">
        {readings.map((reading) => (
          <DimensionCell key={reading.dimension} reading={reading} />
        ))}
      </div>

      {gapNote && (
        <p
          data-testid="score-data-gaps"
          className="flex items-start gap-xxs text-small text-ink/72"
        >
          <ExclamationCircleIcon className="mt-[2px] size-[1.15em] shrink-0" />
          <span>{gapNote}</span>
        </p>
      )}

      {objectiveScore !== null && (
        <>
          <button
            type="button"
            data-testid="score-breakdown-toggle"
            aria-expanded={isExpanded}
            aria-controls={detailId}
            onClick={() => setIsExpanded((value) => !value)}
            className="flex min-h-[44px] w-full items-center justify-between gap-xs text-caption font-semibold text-accent active:opacity-80"
          >
            <span>{isExpanded ? ScoreCopy.hideDetail : ScoreCopy.showDetail}</span>
            <ChevronLeftIcon
              className={cn(
                'size-[16px] shrink-0 transition-transform',
                isExpanded ? 'rotate-90' : '-rotate-90',
              )}
            />
          </button>

          {isExpanded && (
            <div
              id={detailId}
              data-testid="score-breakdown-detail"
              role="group"
              aria-label={ScoreCopy.detailAriaLabel}
              className="flex flex-col gap-xs"
            >
              <p data-testid="score-scale-note" className="text-small text-ink/72">
                {ScoreCopy.scaleNote}
              </p>

              {readings.map((reading) => (
                <div
                  key={reading.dimension}
                  data-testid={`dimension-detail-${reading.dimension}`}
                  className="flex flex-col gap-xxs border-t border-border pt-xs"
                >
                  <div className="flex items-baseline justify-between gap-xs">
                    <span className="flex min-w-0 items-center gap-xxs">
                      {reading.isEmphasized && <EmphasisDot />}
                      <span className="truncate text-caption font-semibold">
                        {scoreDimensionLabel(reading.dimension)}
                      </span>
                    </span>
                    {reading.weight !== null && reading.contribution !== null && (
                      <span className="shrink-0 text-small text-ink/72">
                        {`重み${scorePercent(reading.weight)}・寄与${reading.contribution.toFixed(2)}`}
                      </span>
                    )}
                  </div>
                  {reading.evidence && (
                    <p className="text-small text-ink/72">{reading.evidence}</p>
                  )}
                </div>
              ))}

              <p
                data-testid="objective-score-total"
                className="border-t border-border pt-xs text-small text-ink/72"
              >
                {`${ScoreCopy.weightedTotal} ${objectiveScore.toFixed(2)}。${ScoreCopy.weightedTotalNote}`}
              </p>
            </div>
          )}
        </>
      )}
    </div>
  )
}

interface RecommendationCardProps {
  score: RecommendationScore
  feature: RestaurantFeature | undefined
  explanation: string | undefined
  isExplaining: boolean
  isOrganizer: boolean
  isChosen: boolean
  isChoosing: boolean
  onChoose: () => void
}

export function RecommendationCard({
  score,
  feature,
  explanation,
  isExplaining,
  isOrganizer,
  isChosen,
  isChoosing,
  onChoose,
}: RecommendationCardProps) {
  const name = feature?.name?.trim()
  const title = name && name.length > 0 ? name : 'おすすめのお店'

  const details: string[] = []
  if (feature) {
    if (feature.price_yen_estimate !== null) details.push(`${feature.price_yen_estimate}円前後`)
    const room = roomDescription(feature.room_type)
    if (room) details.push(room)
    // Provider/taxonomy tags are stored as English identifiers, so they must go through
    // the lookup before reaching a Japanese-only screen — otherwise the card reads
    // 「3800円前後・半個室・yakitori」. An unrecognised tag still prints verbatim rather
    // than vanishing, which is the same rule constraintSummary follows.
    details.push(...feature.cuisine_tags.slice(0, 2).map((tag) => cuisineLabel(tag) ?? tag))
  }

  const breakdown = score.score_breakdown
  const readings = breakdown ? readingsFromBreakdown(breakdown) : readingsFromFlatScore(score)
  const gapNote = breakdown ? scoreDataGapNote(breakdown) : null

  return (
    <AppCard>
      <div
        className="flex flex-col gap-md"
        data-testid={`recommendation-card-${score.restaurant_place_id}`}
      >
        <div className="flex h-[150px] items-center justify-center rounded-card bg-accent-soft">
          <ForkKnifeIcon className="size-[42px] text-accent" />
        </div>

        <div className="flex items-start justify-between gap-sm">
          <h3 className="text-title">{title}</h3>
          <span className="shrink-0 rounded-pill bg-yellow px-sm py-xs text-small font-bold text-ink">
            {recommendationBadge(score.label)}
          </span>
        </div>

        {details.length > 0 && (
          <p className="text-caption text-ink/72">{details.join('・')}</p>
        )}

        {explanation ? (
          <p className="text-body">{explanation}</p>
        ) : isExplaining ? (
          <p className="flex items-center gap-xs text-caption">
            <Spinner className="size-[14px]" />
            <span>{AppCopy.writingSummary}</span>
          </p>
        ) : (
          <p className="text-body">{AppCopy.fallbackExplanation}</p>
        )}

        <p className="text-caption font-semibold text-accent">{recommendationText(score.label)}</p>

        <ScoreBreakdownView
          readings={readings}
          gapNote={gapNote}
          objectiveScore={breakdown?.objective_score ?? null}
        />

        {isOrganizer && !isChosen ? (
          <PrimaryButton
            title="このお店に決める"
            icon={<CheckIcon />}
            isLoading={isChoosing}
            onClick={onChoose}
            testId="choose-restaurant"
          />
        ) : isChosen ? (
          <p className="text-body font-bold text-accent">{AppCopy.chosen}</p>
        ) : null}
      </div>
    </AppCard>
  )
}
