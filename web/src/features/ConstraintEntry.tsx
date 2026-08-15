/** Ported from Features/Constraints/ConstraintEntryView.swift. */

import { useEffect, useState } from 'react'
import { useBackend } from '../backend'
import { AppCopy, errorMessage as toMessage, kindTitle, normalizedTypeLabel } from '../design/copy'
import {
  BottomSheet,
  InlineErrorView,
  LoadingStateView,
  SelectionChip,
  StarterChip,
  TextArea,
} from '../design/components'
import { cn } from '../design/cn'
import { constraintSummary } from '../models/format'
import {
  CONSTRAINT_KINDS,
  NORMALIZED_TYPES,
  type ConstraintKind,
  type ConstraintVisibility,
  type NormalizedType,
  type NormalizedValue,
} from '../models/types'

interface PendingConstraint {
  kind: ConstraintKind
  rawText: string
  normalizedType: NormalizedType
  normalizedValue: NormalizedValue
  visibility: ConstraintVisibility
  needsClarification: boolean
}

const EXAMPLES: Record<ConstraintKind, Array<[string, string]>> = {
  MUST: [
    ['予算', '4000円以内'],
    ['ベジタリアン', 'ベジタリアン対応'],
    ['個室', '個室が必要'],
    ['アレルギー', 'えびが食べられない'],
  ],
  WANT: [
    ['料理', '和食がいい'],
    ['静か', '静かに話せる場所'],
    ['飲み物', 'お酒が充実'],
  ],
}

interface ConstraintEntryProps {
  eventId: string
  participantId: string
}

export function ConstraintEntry({ eventId, participantId }: ConstraintEntryProps) {
  const backend = useBackend()
  const [drafts, setDrafts] = useState<Record<ConstraintKind, string>>({ MUST: '', WANT: '' })
  const [pending, setPending] = useState<PendingConstraint | null>(null)
  const [parsingKind, setParsingKind] = useState<ConstraintKind | null>(null)
  const [isLoading, setIsLoading] = useState(true)
  const [errorMessage, setErrorMessage] = useState<string | null>(null)
  const [savedCount, setSavedCount] = useState(0)

  useEffect(() => {
    let active = true
    void (async () => {
      try {
        const saved = await backend.ownConstraints(participantId)
        if (!active) return
        const nextDrafts: Record<ConstraintKind, string> = { MUST: '', WANT: '' }
        for (const constraint of saved) nextDrafts[constraint.kind] = constraint.raw_text
        setDrafts(nextDrafts)
        setSavedCount(saved.length)
      } catch (error) {
        if (active) setErrorMessage(toMessage(error))
      }
      if (active) setIsLoading(false)
    })()
    return () => {
      active = false
    }
  }, [backend, participantId])

  const parse = async (kind: ConstraintKind) => {
    const rawText = (drafts[kind] ?? '').trim()
    if (rawText.length === 0) return
    setParsingKind(kind)
    setErrorMessage(null)
    try {
      const result = await backend.parse({ rawText, kind, language: 'ja' })
      setPending({
        kind,
        rawText,
        normalizedType: result.normalized_type,
        normalizedValue: result.normalized_value,
        visibility: result.suggested_visibility,
        needsClarification: result.needs_clarification,
      })
    } catch (error) {
      setErrorMessage(toMessage(error))
    }
    setParsingKind(null)
  }

  const save = async (constraint: PendingConstraint) => {
    await backend.insertConstraint({
      eventId,
      participantId,
      kind: constraint.kind,
      rawText: constraint.rawText,
      normalizedType: constraint.normalizedType,
      normalizedValue: constraint.normalizedValue,
      visibility: constraint.visibility,
    })
    setDrafts((current) => ({ ...current, [constraint.kind]: '' }))
    setSavedCount((count) => count + 1)
    setPending(null)
  }

  return (
    <div className="flex flex-col gap-xl px-lg pb-xxl pt-md">
      <div className="flex flex-col gap-xs">
        <h2 className="text-title">{AppCopy.homeRequirements}</h2>
        <p className="text-body text-ink/72">みんなで納得できるお店の条件を教えてください。</p>
      </div>

      {isLoading ? (
        <LoadingStateView title="保存した希望を読み込んでいます" />
      ) : (
        <>
          {CONSTRAINT_KINDS.map((kind) => (
            <section key={kind} className="flex flex-col gap-sm">
              <h3 className="text-section">{kindTitle(kind)}</h3>
              <div className="flex flex-wrap gap-xs">
                {EXAMPLES[kind].map(([label, text]) => (
                  <StarterChip
                    key={label}
                    title={label}
                    tint={kind === 'MUST' ? 'accent-soft' : 'yellow'}
                    onClick={() => setDrafts((current) => ({ ...current, [kind]: text }))}
                  />
                ))}
              </div>
              <TextArea
                value={drafts[kind] ?? ''}
                placeholder="自由に入力してください…"
                onChange={(value) => setDrafts((current) => ({ ...current, [kind]: value }))}
                testId={`draft-${kind}`}
              />
              <button
                type="button"
                onClick={() => void parse(kind)}
                disabled={parsingKind !== null || (drafts[kind] ?? '').trim().length === 0}
                data-testid={`next-${kind}`}
                className={cn(
                  'min-h-[44px] self-end rounded-pill bg-accent px-lg text-body font-bold text-white',
                  'transition-opacity active:opacity-80 disabled:opacity-45',
                )}
              >
                {parsingKind === kind ? AppCopy.loading : '次へ'}
              </button>
            </section>
          ))}

          {savedCount > 0 && (
            <p className="text-center text-caption text-ink/72">
              {savedCount}件の希望を保存しました。
            </p>
          )}
        </>
      )}

      {errorMessage && (
        <InlineErrorView message={errorMessage} onRetry={() => setErrorMessage(null)} />
      )}

      <ConstraintConfirmSheet
        pending={pending}
        onChange={setPending}
        onDismiss={() => setPending(null)}
        onConfirm={save}
      />
    </div>
  )
}

interface ConfirmSheetProps {
  pending: PendingConstraint | null
  onChange: (pending: PendingConstraint) => void
  onDismiss: () => void
  onConfirm: (pending: PendingConstraint) => Promise<void>
}

function ConstraintConfirmSheet({ pending, onChange, onDismiss, onConfirm }: ConfirmSheetProps) {
  const [isSaving, setIsSaving] = useState(false)
  const [errorMessage, setErrorMessage] = useState<string | null>(null)

  useEffect(() => {
    if (pending) {
      setIsSaving(false)
      setErrorMessage(null)
    }
  }, [pending])

  const confirm = async () => {
    if (!pending || isSaving) return
    setIsSaving(true)
    setErrorMessage(null)
    try {
      await onConfirm(pending)
    } catch (error) {
      setErrorMessage(toMessage(error))
    }
    setIsSaving(false)
  }

  return (
    <BottomSheet
      title="こう解釈しました"
      isOpen={pending !== null}
      dismissDisabled={isSaving}
      onDismiss={onDismiss}
    >
      {pending && (
        <div className="flex flex-col gap-md">
          <p className="text-section">
            {constraintSummary(pending.normalizedType, pending.normalizedValue)}
          </p>
          <p className="text-body text-ink/72">「{pending.rawText}」</p>

          {pending.needsClarification && (
            <p className="text-caption text-accent">近い分類を選んでください。</p>
          )}

          {errorMessage && (
            <InlineErrorView message={errorMessage} onRetry={() => setErrorMessage(null)} />
          )}

          <label className="flex items-center justify-between gap-sm">
            <span className="text-body">分類</span>
            <select
              value={pending.normalizedType}
              onChange={(nativeEvent) =>
                onChange({
                  ...pending,
                  normalizedType: nativeEvent.target.value as NormalizedType,
                })
              }
              data-testid="normalized-type"
              className="min-h-[44px] rounded-field border border-border bg-card px-sm text-body text-accent"
            >
              {NORMALIZED_TYPES.map((type) => (
                <option key={type} value={type}>
                  {normalizedTypeLabel(type)}
                </option>
              ))}
            </select>
          </label>

          <div className="flex flex-wrap gap-xs">
            <SelectionChip
              title={AppCopy.showName}
              isSelected={pending.visibility === 'PUBLIC'}
              onClick={() => onChange({ ...pending, visibility: 'PUBLIC' })}
            />
            <SelectionChip
              title={AppCopy.anonymous}
              isSelected={pending.visibility === 'ANONYMOUS'}
              onClick={() => onChange({ ...pending, visibility: 'ANONYMOUS' })}
            />
          </div>

          <div className="flex gap-sm">
            <button
              type="button"
              onClick={onDismiss}
              disabled={isSaving}
              className="min-h-[48px] flex-1 rounded-pill border border-border bg-card text-body font-semibold text-ink disabled:opacity-45"
            >
              {AppCopy.cancel}
            </button>
            <button
              type="button"
              onClick={() => void confirm()}
              disabled={isSaving}
              data-testid="save-constraint"
              className="min-h-[48px] flex-1 rounded-pill bg-accent text-body font-bold text-white disabled:opacity-45"
            >
              {isSaving ? AppCopy.loading : AppCopy.save}
            </button>
          </div>
        </div>
      )}
    </BottomSheet>
  )
}
