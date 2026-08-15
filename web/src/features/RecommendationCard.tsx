/** Ported from Features/Recommendations/RecommendationCardView.swift. */

import { AppCopy, recommendationBadge, recommendationText } from '../design/copy'
import { AppCard, PrimaryButton } from '../design/components'
import { CheckIcon, ForkKnifeIcon, Spinner } from '../design/icons'
import { roomDescription } from '../models/format'
import type { RecommendationScore, RestaurantFeature } from '../models/types'

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
    details.push(...feature.cuisine_tags.slice(0, 2))
  }

  return (
    <AppCard>
      <div className="flex flex-col gap-md">
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
