/** Ported from Features/Organizer/OrganizerDashboardView.swift (view + view model). */

import { useCallback, useEffect, useState } from 'react'
import { useBackend } from '../backend'
import { AppCopy } from '../design/copy'
import { AppCard, InlineErrorView, PrimaryButton, StatTile } from '../design/components'
import { CheckSealIcon } from '../design/icons'
import type { EventDecision } from '../models/types'

interface OrganizerDashboardProps {
  eventId: string
  decision: EventDecision | null
  chosenRestaurantName: string | null
  onOpenRecommendations: (runId: string) => void
}

export function OrganizerDashboard({
  eventId,
  decision,
  chosenRestaurantName,
  onOpenRecommendations,
}: OrganizerDashboardProps) {
  const backend = useBackend()
  const [responseCount, setResponseCount] = useState(0)
  const [feasibleCount, setFeasibleCount] = useState<number | null>(null)
  const [openNegotiations, setOpenNegotiations] = useState(0)
  const [latestRunId, setLatestRunId] = useState<string | null>(null)
  const [isWorking, setIsWorking] = useState(false)
  const [statusMessage, setStatusMessage] = useState<string | null>(null)
  const [errorMessage, setErrorMessage] = useState<string | null>(null)

  const negotiationInProgress = openNegotiations > 0

  const load = useCallback(async () => {
    try {
      setResponseCount(await backend.responseCount(eventId))
      setOpenNegotiations(await backend.pendingNegotiationCount(eventId))
      const run = await backend.latestRun(eventId)
      if (run) {
        setFeasibleCount(run.feasible_count)
        setLatestRunId(run.id)
      }
    } catch {
      setErrorMessage(AppCopy.networkError)
    }
  }, [backend, eventId])

  useEffect(() => {
    void load()
  }, [load])

  // listenForRuns(eventId:) — the feasible count is push-driven, not polled.
  useEffect(() => {
    let active = true
    let unsubscribe: (() => void) | undefined
    void (async () => {
      try {
        unsubscribe = await backend.subscribeRuns(eventId, (update) => {
          setFeasibleCount(update.feasible_count)
          setLatestRunId(update.run_id)
          void (async () => {
            try {
              setOpenNegotiations(await backend.pendingNegotiationCount(eventId))
              setResponseCount(await backend.responseCount(eventId))
            } catch {
              setErrorMessage(AppCopy.networkError)
            }
          })()
        })
      } catch {
        if (active) setErrorMessage(AppCopy.networkError)
      }
    })()
    return () => {
      active = false
      unsubscribe?.()
    }
  }, [backend, eventId])

  const findRestaurants = async () => {
    if (isWorking) return
    setIsWorking(true)
    setErrorMessage(null)
    setStatusMessage(null)
    try {
      const candidates = await backend.findRestaurants(eventId)
      const result = await backend.recomputeFeasibility(eventId)
      setFeasibleCount(result.feasible_count)
      setLatestRunId(result.run_id)

      if (result.feasible_count === 0) {
        const negotiationId = await backend.proposeRelaxation(eventId)
        setStatusMessage(
          negotiationId === null
            ? '今の条件では、まだ候補が見つかりません。みんなで相談してみましょう。'
            : '条件に合うお店がありません。参加者に条件の変更をお願いしました。',
        )
        try {
          setOpenNegotiations(await backend.pendingNegotiationCount(eventId))
        } catch {
          setErrorMessage(AppCopy.networkError)
        }
      } else if (candidates === 0) {
        setStatusMessage('以前に取得した候補を表示しています。')
      }
    } catch {
      setErrorMessage(AppCopy.networkError)
    }
    setIsWorking(false)
  }

  return (
    <div className="flex flex-col gap-xl px-lg pb-xxl pt-md">
      <div className="flex flex-col gap-xs">
        <h2 className="text-title">{AppCopy.homeOrganizer}</h2>
        <p className="text-body text-ink/72">みんなの条件を集計して、お店を探します。</p>
      </div>

      <div className="flex gap-sm">
        <StatTile value={String(responseCount)} title="回答数" tint="card" testId="response-count" />
        <StatTile
          value={feasibleCount === null ? '—' : String(feasibleCount)}
          title="条件を満たすお店"
          tint={(feasibleCount ?? 0) > 0 ? 'accent-soft' : 'card'}
          testId="feasible-count"
        />
      </div>

      {negotiationInProgress && (
        <span className="flex min-h-[36px] items-center self-start rounded-pill bg-yellow px-md text-caption font-bold text-ink">
          調整中…
        </span>
      )}

      <PrimaryButton
        title={AppCopy.findRestaurants}
        isLoading={isWorking}
        onClick={() => void findRestaurants()}
        testId="find-restaurants"
      />

      {latestRunId && (feasibleCount ?? 0) > 0 && (
        <button
          type="button"
          onClick={() => onOpenRecommendations(latestRunId)}
          data-testid="recommendations"
          className="min-h-[48px] w-full rounded-pill border-[1.5px] border-dashed border-border bg-card text-body font-semibold text-ink active:opacity-80"
        >
          おすすめを見る
        </button>
      )}

      {decision?.chosen_place_id && (
        <AppCard>
          <p className="flex items-center gap-xs text-accent">
            <CheckSealIcon />
            <span>
              {chosenRestaurantName ? `${AppCopy.chosen}：${chosenRestaurantName}` : AppCopy.chosen}
            </span>
          </p>
        </AppCard>
      )}

      <p className="text-caption text-ink/72">
        誰がどの条件を出したかは表示せず、集計結果だけを共有します。
      </p>

      {statusMessage && <p className="text-body">{statusMessage}</p>}

      {errorMessage && <InlineErrorView message={errorMessage} onRetry={() => void load()} />}
    </div>
  )
}
