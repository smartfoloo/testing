/**
 * Ported from Features/Organizer/OrganizerDashboardView.swift (view + view model).
 *
 * Beyond the Swift original this screen carries the two PRD §12 organizer affordances:
 *  - progressive search: how far collection has come, and whether a search right now is
 *    provisional (`fn_get_collection_readiness`);
 *  - closing preference collection (`fn_close_preferences`), which deliberately does not
 *    recompute — post-close recalculation is an explicit act by the 幹事.
 * Keep OrganizerDashboardView.swift in step when this changes.
 */

import { useCallback, useEffect, useState } from 'react'
import { useBackend } from '../backend'
import {
  AppCopy,
  closedAtText,
  closeSnapshotText,
  errorMessage as errorMessageFor,
  readinessCounts,
  readinessHint,
  readinessSummary,
  resultBasisText,
} from '../design/copy'
import {
  AppCard,
  BottomSheet,
  InlineErrorView,
  PrimaryButton,
  SecondaryButton,
  StatTile,
} from '../design/components'
import { CheckSealIcon } from '../design/icons'
import type { CollectionReadiness, EventDecision } from '../models/types'

interface OrganizerDashboardProps {
  eventId: string
  decision: EventDecision | null
  chosenRestaurantName: string | null
  onOpenRecommendations: (runId: string) => void
}

/**
 * Progress towards the threshold. The filled part is answers received; the notch is the
 * point at which a shortlist stops being a coin flip (least(n, greatest(3, ceil(0.6n)))).
 */
function ReadinessBar({ readiness }: { readiness: CollectionReadiness }) {
  const total = Math.max(readiness.participant_count, 1)
  const filled = Math.min(100, Math.round((readiness.responded_count / total) * 100))
  const mark = Math.min(100, Math.round((readiness.threshold_count / total) * 100))
  return (
    <div
      role="progressbar"
      aria-label={AppCopy.collectionProgress}
      aria-valuemin={0}
      aria-valuemax={readiness.participant_count}
      aria-valuenow={readiness.responded_count}
      aria-valuetext={readinessCounts(readiness)}
      data-testid="readiness-progress"
      data-responded={readiness.responded_count}
      data-participants={readiness.participant_count}
      data-threshold={readiness.threshold_count}
      className="relative h-xs w-full overflow-hidden rounded-pill bg-accent-soft"
    >
      <div className="h-full rounded-pill bg-accent" style={{ width: `${filled}%` }} />
      {readiness.threshold_count < readiness.participant_count && (
        <span
          aria-hidden="true"
          className="absolute inset-y-0 w-[2px] bg-ink/45"
          style={{ left: `${mark}%` }}
        />
      )}
    </div>
  )
}

/** A calm status pill, matching the 調整中… treatment but without the warning yellow. */
function StatePill({ title, testId }: { title: string; testId: string }) {
  return (
    <span
      data-testid={testId}
      className="flex min-h-[36px] items-center self-start rounded-pill bg-green-soft px-md text-caption font-bold text-ink"
    >
      {title}
    </span>
  )
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
  const [latestRunAt, setLatestRunAt] = useState<string | null>(null)
  const [readiness, setReadiness] = useState<CollectionReadiness | null>(null)
  /** Readiness as it stood when the run currently on screen landed. */
  const [runBasis, setRunBasis] = useState<CollectionReadiness | null>(null)
  const [isWorking, setIsWorking] = useState(false)
  const [isClosing, setIsClosing] = useState(false)
  const [isConfirmingClose, setIsConfirmingClose] = useState(false)
  const [statusMessage, setStatusMessage] = useState<string | null>(null)
  const [errorMessage, setErrorMessage] = useState<string | null>(null)

  const negotiationInProgress = openNegotiations > 0
  const preferencesClosed = readiness?.preferences_closed ?? false
  const closedAt = closedAtText(readiness?.preferences_closed_at ?? null)
  // Answers can still arrive, so anything computed now is provisional — whether or not
  // the threshold has been reached. PRD §12 wants that said out loud, not implied.
  const answersComplete =
    readiness !== null &&
    readiness.participant_count > 0 &&
    readiness.responded_count >= readiness.participant_count
  const resultsProvisional = readiness !== null && !preferencesClosed && !answersComplete

  // The shortlist on screen predates the close, so it is not the post-close answer yet.
  // PRD §12: that recalculation is the organizer's explicit act, never a side effect.
  const closedAtMs = readiness?.preferences_closed_at
    ? Date.parse(readiness.preferences_closed_at)
    : null
  const runAtMs = latestRunAt ? Date.parse(latestRunAt) : null
  const needsRecompute =
    preferencesClosed &&
    closedAtMs !== null &&
    !Number.isNaN(closedAtMs) &&
    (runAtMs === null || Number.isNaN(runAtMs) || runAtMs < closedAtMs)

  const refreshReadiness = useCallback(async (): Promise<CollectionReadiness | null> => {
    try {
      const next = await backend.collectionReadiness(eventId)
      setReadiness(next)
      return next
    } catch (error) {
      setErrorMessage(errorMessageFor(error))
      return null
    }
  }, [backend, eventId])

  const load = useCallback(async () => {
    try {
      setResponseCount(await backend.responseCount(eventId))
      setOpenNegotiations(await backend.pendingNegotiationCount(eventId))
      const run = await backend.latestRun(eventId)
      if (run) {
        setFeasibleCount(run.feasible_count)
        setLatestRunId(run.id)
        setLatestRunAt(run.run_at)
      }
    } catch {
      setErrorMessage(AppCopy.networkError)
    }
    await refreshReadiness()
  }, [backend, eventId, refreshReadiness])

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
          setLatestRunAt(new Date().toISOString())
          void (async () => {
            try {
              setOpenNegotiations(await backend.pendingNegotiationCount(eventId))
              setResponseCount(await backend.responseCount(eventId))
            } catch {
              setErrorMessage(AppCopy.networkError)
            }
            // Keep the readiness readout in step with the run that just arrived.
            const next = await refreshReadiness()
            if (next) setRunBasis(next)
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
  }, [backend, eventId, refreshReadiness])

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
      setLatestRunAt(new Date().toISOString())

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
    // The search is what makes the numbers move, so re-read them instead of going stale.
    const next = await refreshReadiness()
    if (next) setRunBasis(next)
    setIsWorking(false)
  }

  const closePreferences = async () => {
    // fn_close_preferences is idempotent, but a double tap would still fire two RPCs.
    if (isClosing || preferencesClosed) return
    setIsClosing(true)
    setErrorMessage(null)
    setStatusMessage(null)
    try {
      setReadiness(await backend.closePreferences(eventId))
    } catch (error) {
      setErrorMessage(errorMessageFor(error))
    }
    setIsClosing(false)
    setIsConfirmingClose(false)
  }

  return (
    <div className="flex flex-col gap-xl px-lg pb-xxl pt-md">
      <div className="flex flex-col gap-xs">
        <h2 className="text-title">{AppCopy.homeOrganizer}</h2>
        <p className="text-body text-ink/72">みんなの条件を集計して、お店を探します。</p>
      </div>

      <div className="flex gap-sm">
        {/*
          回答数 counts people once readiness is known: fn_get_response_count returns
          constraint rows, which reads as "10 answers from 5 people" and overstates the
          coverage the shortlist is actually based on.
        */}
        <StatTile
          value={
            readiness
              ? `${readiness.responded_count}/${readiness.participant_count}`
              : String(responseCount)
          }
          title="回答数"
          tint="card"
          testId="response-count"
        />
        <StatTile
          value={feasibleCount === null ? '—' : String(feasibleCount)}
          title="条件を満たすお店"
          tint={(feasibleCount ?? 0) > 0 ? 'accent-soft' : 'card'}
          testId="feasible-count"
        />
      </div>

      {readiness && (
        <AppCard>
          <div data-testid="collection-readiness" className="flex flex-col gap-sm">
            <div className="flex flex-wrap items-center justify-between gap-xs">
              <span className="text-section">{AppCopy.collectionProgress}</span>
              {preferencesClosed ? (
                <StatePill title={AppCopy.preferencesClosedBadge} testId="preferences-closed" />
              ) : (
                resultsProvisional && (
                  <span
                    data-testid="provisional-badge"
                    className="rounded-pill bg-accent-soft px-sm py-xxs text-small font-bold text-ink"
                  >
                    {AppCopy.provisionalBadge}
                  </span>
                )
              )}
            </div>
            <ReadinessBar readiness={readiness} />
            <p className="text-caption text-ink/72" data-testid="readiness-counts">
              {readinessCounts(readiness)}
            </p>
            <p className="text-body" data-testid="readiness-summary">
              {readinessSummary(readiness)}
            </p>
            <p className="text-caption text-ink/72" data-testid="readiness-hint">
              {readinessHint(readiness)}
            </p>
            {preferencesClosed && closedAt && (
              <p className="text-caption text-ink/72" data-testid="preferences-closed-at">
                {closedAt}
              </p>
            )}
          </div>
        </AppCard>
      )}

      {negotiationInProgress && (
        <span className="flex min-h-[36px] items-center self-start rounded-pill bg-yellow px-md text-caption font-bold text-ink">
          調整中…
        </span>
      )}

      <div className="flex flex-col gap-sm">
        {needsRecompute && (
          <p
            data-testid="recompute-required"
            className="rounded-card bg-green-soft px-md py-sm text-caption text-ink"
          >
            {AppCopy.recomputeRequired}
          </p>
        )}

        <PrimaryButton
          title={AppCopy.findRestaurants}
          isLoading={isWorking}
          onClick={() => void findRestaurants()}
          testId="find-restaurants"
        />
      </div>

      {latestRunId && (feasibleCount ?? 0) > 0 && (
        <div className="flex flex-col gap-sm">
          <button
            type="button"
            onClick={() => onOpenRecommendations(latestRunId)}
            data-testid="recommendations"
            className="min-h-[48px] w-full rounded-pill border-[1.5px] border-dashed border-border bg-card text-body font-semibold text-ink active:opacity-80"
          >
            おすすめを見る
          </button>
          <p className="text-caption text-ink/72" data-testid="result-basis">
            {resultBasisText(runBasis)}
          </p>
        </div>
      )}

      {!preferencesClosed && (
        <SecondaryButton
          title={AppCopy.closePreferences}
          disabled={isClosing || readiness === null}
          onClick={() => setIsConfirmingClose(true)}
          testId="close-preferences"
        />
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

      <BottomSheet
        title={AppCopy.closePreferencesQuestion}
        isOpen={isConfirmingClose}
        dismissDisabled={isClosing}
        onDismiss={() => {
          if (!isClosing) setIsConfirmingClose(false)
        }}
      >
        <div className="flex flex-col gap-md" data-testid="close-preferences-sheet">
          <p className="text-body">{AppCopy.closePreferencesEffect}</p>
          <p className="text-body">{AppCopy.closePreferencesNoRecompute}</p>
          <p className="text-caption text-ink/72">{AppCopy.closePreferencesIrreversible}</p>
          {readiness && (
            <p className="text-caption text-ink/72" data-testid="close-preferences-snapshot">
              {closeSnapshotText(readiness)}
            </p>
          )}
          <PrimaryButton
            title={AppCopy.closePreferencesConfirm}
            isLoading={isClosing}
            onClick={() => void closePreferences()}
            testId="close-preferences-confirm"
          />
          <SecondaryButton
            title={AppCopy.cancel}
            disabled={isClosing}
            onClick={() => setIsConfirmingClose(false)}
            testId="close-preferences-cancel"
          />
        </div>
      </BottomSheet>
    </div>
  )
}
