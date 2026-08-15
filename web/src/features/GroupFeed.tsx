/** Ported from Features/Activity/GroupActivityFeedView.swift. */

import { useCallback, useEffect, useState } from 'react'
import { useBackend } from '../backend'
import { AppCopy, kindTitle } from '../design/copy'
import { AppCard, EmptyStateView, InlineErrorView, LoadingStateView } from '../design/components'
import { constraintSummary } from '../models/format'
import type { FeedItem } from '../models/types'

export function GroupFeed({ eventId }: { eventId: string }) {
  const backend = useBackend()
  const [items, setItems] = useState<FeedItem[]>([])
  const [isLoading, setIsLoading] = useState(true)
  const [errorMessage, setErrorMessage] = useState<string | null>(null)
  const [lastPayload, setLastPayload] = useState<string | null>(null)
  const [reloadToken, setReloadToken] = useState(0)

  const retry = useCallback(() => setReloadToken((token) => token + 1), [])

  useEffect(() => {
    let active = true
    let unsubscribe: (() => void) | undefined

    void (async () => {
      setIsLoading(true)
      setErrorMessage(null)
      try {
        const history = await backend.sanitizedFeed(eventId)
        if (!active) return
        setItems(history)

        unsubscribe = await backend.subscribeConstraints(eventId, (item) => {
          if (import.meta.env.DEV) setLastPayload(describe(item))
          // The broadcast only covers inserts after subscribing, so de-duplicate
          // against the history load.
          setItems((current) =>
            current.some((existing) => existing.id === item.id) ? current : [...current, item],
          )
        })
        if (active) setIsLoading(false)
      } catch {
        if (active) {
          setIsLoading(false)
          setErrorMessage(AppCopy.networkError)
        }
      }
    })()

    return () => {
      active = false
      unsubscribe?.()
    }
  }, [backend, eventId, reloadToken])

  return (
    <div className="flex flex-col gap-lg px-lg pb-xxl pt-md">
      <div className="flex flex-col gap-xs">
        <h2 className="text-title">{AppCopy.homeGroup}</h2>
        <p className="text-body text-ink/72">共有された希望だけが、ここに表示されます。</p>
      </div>

      {isLoading ? (
        <LoadingStateView title="みんなの状況を読み込んでいます" />
      ) : items.length === 0 ? (
        <EmptyStateView
          title="まだ共有された希望はありません"
          message="希望が保存されると、ここに表示されます。"
        />
      ) : (
        items.map((item) => (
          <AppCard key={item.id}>
            <div className="flex flex-col gap-sm">
              <div className="flex items-center justify-between gap-sm">
                <span className="text-caption font-bold">
                  {item.display_name ?? '匿名の参加者'}
                </span>
                <span
                  className={`rounded-pill px-sm py-xxs text-small font-bold ${
                    item.kind === 'MUST' ? 'bg-accent-soft' : 'bg-yellow'
                  }`}
                >
                  {kindTitle(item.kind)}
                </span>
              </div>
              <p className="text-body">
                {constraintSummary(item.normalized_type, item.normalized_value)}
              </p>
            </div>
          </AppCard>
        ))
      )}

      {import.meta.env.DEV && lastPayload && (
        <AppCard>
          <div className="flex flex-col gap-xs">
            <p className="text-caption font-bold">デバッグ：最後に受け取った共有データ</p>
            <pre className="whitespace-pre-wrap font-mono text-small select-all">{lastPayload}</pre>
          </div>
        </AppCard>
      )}

      {errorMessage && <InlineErrorView message={errorMessage} onRetry={retry} />}
    </div>
  )
}

/** Mirrors GroupActivityFeedView.describe(_:) so the wire payload can be eyeballed. */
function describe(payload: FeedItem): string {
  return Object.entries(payload as unknown as Record<string, unknown>)
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, value]) => `${key}: ${value === null ? 'null' : JSON.stringify(value)}`)
    .join('\n')
}
