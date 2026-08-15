/**
 * Ported from Features/Constraints/ConstraintEntryView.swift.
 *
 * Beyond the Swift original this screen also owns the participant's 移動の基準. PRD §4
 * files the travel reference under "Context — not itself a constraint; changeable later",
 * but it was only ever settable on the create/join screen, so anyone who skipped the
 * place picker there could never contribute a travel origin: `restaurant-search` reports
 * them as unresolved for the rest of the event and travel fairness silently degrades for
 * the whole group. This is that screen — the one place each participant answers only for
 * themselves — so the change lives here rather than on the organizer's.
 */

import { useEffect, useState } from 'react'
import { useBackend } from '../backend'
import {
  AppCopy,
  TravelCopy,
  TravelEditCopy,
  errorMessage as toMessage,
  kindTitle,
  normalizedTypeLabel,
  travelCurrentHint,
  travelCurrentText,
  travelLabel,
  travelPlaceLabel,
} from '../design/copy'
import {
  AppCard,
  BottomSheet,
  Divider,
  InlineErrorView,
  LoadingStateView,
  PrimaryButton,
  SecondaryButton,
  SelectionChip,
  StarterChip,
  TextArea,
  TextField,
} from '../design/components'
import { ArrowRightIcon } from '../design/icons'
import { cn } from '../design/cn'
import { constraintSummary } from '../models/format'
import {
  CONSTRAINT_KINDS,
  NORMALIZED_TYPES,
  TRAVEL_REFERENCES,
  type ConstraintKind,
  type ConstraintVisibility,
  type NormalizedType,
  type NormalizedValue,
  type ParticipantTravel,
  type PlaceSuggestion,
  type TravelReference,
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
  /** The stored 移動の基準, so the editor opens on reality instead of a default. */
  const [travel, setTravel] = useState<ParticipantTravel | null>(null)
  const [isEditingTravel, setIsEditingTravel] = useState(false)
  const [travelSaved, setTravelSaved] = useState(false)

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
      try {
        // Read separately: a travel reference that fails to load must not cost the
        // participant the requirements they already saved, and vice versa.
        const current = await backend.participantTravel(participantId)
        if (active) setTravel(current)
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

          <Divider />

          {/*
            移動の基準 is context, not a requirement (PRD §4), so it sits below the two
            requirement sections and is worded as a setting rather than a wish. Collapsed
            into a summary card: nobody needs to re-answer it every time they open the tab,
            but the consequence of leaving the place empty is on screen either way.

            It stays editable after the 幹事 closes preference collection, because what
            0018 closes is the collection of requirements — see 0020's header.
          */}
          <section className="flex flex-col gap-sm">
            <h3 className="text-section">{TravelCopy.sectionTitle}</h3>
            <AppCard className="flex flex-col gap-xs">
              <p className="text-body" data-testid="travel-current">
                {travelCurrentText(
                  travel?.travel_reference ?? null,
                  travel?.travel_reference_place_id ?? null,
                )}
              </p>
              <p className="text-caption text-ink/72" data-testid="travel-current-hint">
                {travelCurrentHint(
                  travel?.travel_reference ?? null,
                  travel?.travel_reference_place_id ?? null,
                )}
              </p>
              {travelSaved && (
                <p className="text-caption text-accent" data-testid="travel-saved">
                  {TravelEditCopy.saved}
                </p>
              )}
            </AppCard>
            <SecondaryButton
              title={
                travel?.travel_reference_place_id ? TravelEditCopy.change : TravelEditCopy.set
              }
              onClick={() => {
                setTravelSaved(false)
                setIsEditingTravel(true)
              }}
              testId="edit-travel-reference"
            />
          </section>
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

      <TravelReferenceSheet
        isOpen={isEditingTravel}
        current={travel}
        onDismiss={() => setIsEditingTravel(false)}
        onSave={async (next) => {
          const updated = await backend.updateTravelReference({
            participantId,
            travelReference: next.reference,
            travelReferencePlaceId: next.placeId,
          })
          setTravel(updated)
          setTravelSaved(true)
          setIsEditingTravel(false)
        }}
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

/* -------------------------------------------------------------------------- */
/* 移動の基準 — the participant's own travel reference                          */
/* -------------------------------------------------------------------------- */

/** One provider call per pause in typing, never one per keystroke. */
const PLACE_SEARCH_DEBOUNCE_MS = 350
/** The place-search Edge Function's own minimum, so a too-short query never leaves. */
const MIN_PLACE_QUERY_CHARS = 2
const MAX_PLACE_QUERY_CHARS = 120

interface TravelReferenceSheetProps {
  isOpen: boolean
  /** What is stored right now; null while it is still loading or failed to load. */
  current: ParticipantTravel | null
  onDismiss: () => void
  onSave: (next: { reference: TravelReference; placeId: string | null }) => Promise<void>
}

/**
 * Category + place, for the participant themselves.
 *
 * Three things this has to get right:
 *  - it opens on the STORED values, so opening the sheet and saving cannot silently
 *    replace a correct answer with 会社;
 *  - どこでも clears the place id, because it means "no travel constraint" and a
 *    leftover place would put the participant back into the origins set;
 *  - only the place id is stored, so a place chosen earlier has no name to show. It is
 *    described as 設定済み rather than rendered as an opaque provider id.
 */
function TravelReferenceSheet({ isOpen, current, onDismiss, onSave }: TravelReferenceSheetProps) {
  const backend = useBackend()
  const [reference, setReference] = useState<TravelReference>('office')
  const [placeId, setPlaceId] = useState<string | null>(null)
  /** Known only for a place picked in this session; a stored id has no name. */
  const [placeName, setPlaceName] = useState<string | null>(null)
  const [query, setQuery] = useState('')
  const [results, setResults] = useState<PlaceSuggestion[]>([])
  const [status, setStatus] = useState<'idle' | 'searching' | 'empty' | 'failed'>('idle')
  /** Bumped by 「もう一度試す」 so a retry re-runs the effect for an unchanged query. */
  const [attempt, setAttempt] = useState(0)
  const [isSaving, setIsSaving] = useState(false)
  const [errorMessage, setErrorMessage] = useState<string | null>(null)

  // Every open starts from what the database actually holds, never from the last edit.
  useEffect(() => {
    if (!isOpen) return
    setReference(current?.travel_reference ?? 'office')
    setPlaceId(current?.travel_reference_place_id ?? null)
    setPlaceName(null)
    setQuery('')
    setResults([])
    setStatus('idle')
    setIsSaving(false)
    setErrorMessage(null)
  }, [isOpen, current])

  const needsPlace = reference !== 'doesnt_matter'
  const trimmed = query.trim()
  const isSearching =
    isOpen && needsPlace && placeId === null && trimmed.length >= MIN_PLACE_QUERY_CHARS

  useEffect(() => {
    if (!isSearching) {
      setResults([])
      setStatus('idle')
      return
    }
    let active = true
    setStatus('searching')
    // This runs on every keystroke, but only the last timer of a burst survives the
    // cleanup, so the provider sees one query per pause in typing.
    const timer = setTimeout(() => {
      void (async () => {
        try {
          const found = await backend.searchPlaces(trimmed)
          if (!active) return
          setResults(found)
          setStatus(found.length === 0 ? 'empty' : 'idle')
        } catch {
          // A dead provider must not read as "no such place".
          if (!active) return
          setResults([])
          setStatus('failed')
        }
      })()
    }, PLACE_SEARCH_DEBOUNCE_MS)
    return () => {
      // Also drops the in-flight answer, so a slow early request cannot overwrite the
      // results of a later, narrower query.
      active = false
      clearTimeout(timer)
    }
  }, [backend, isSearching, trimmed, attempt])

  const selectReference = (next: TravelReference) => {
    setQuery('')
    setReference(next)
    // どこでも carries no location by definition; the other three keep the place, so
    // relabelling 会社 as 駅 does not throw away a correct origin.
    if (next === 'doesnt_matter') {
      setPlaceId(null)
      setPlaceName(null)
    }
  }

  const submit = async () => {
    if (isSaving) return
    setIsSaving(true)
    setErrorMessage(null)
    try {
      await onSave({ reference, placeId: needsPlace ? placeId : null })
    } catch (error) {
      // A refusal (someone else's row, a closed session) is surfaced, never swallowed.
      setErrorMessage(toMessage(error))
    }
    setIsSaving(false)
  }

  return (
    <BottomSheet
      title={TravelEditCopy.sheetTitle}
      isOpen={isOpen}
      dismissDisabled={isSaving}
      onDismiss={onDismiss}
    >
      <div className="flex flex-col gap-md" data-testid="travel-reference-sheet">
        <p className="text-body text-ink/72">{TravelCopy.sectionHelp}</p>

        <div className="flex flex-wrap gap-xs">
          {TRAVEL_REFERENCES.map((value) => (
            <SelectionChip
              key={value}
              title={travelLabel(value)}
              isSelected={reference === value}
              onClick={() => selectReference(value)}
              testId={`travel-edit-reference-${value}`}
            />
          ))}
        </div>

        {needsPlace &&
          (placeId !== null ? (
            <div className="flex items-center justify-between gap-sm rounded-card bg-card p-md">
              <span
                data-testid="travel-edit-place-selected"
                className="flex min-w-0 flex-col gap-xxs"
              >
                <span className="text-body font-semibold">
                  {placeName ?? TravelEditCopy.storedPlace}
                </span>
                <span className="text-caption text-ink/72">{travelPlaceLabel(reference)}</span>
              </span>
              <button
                type="button"
                onClick={() => {
                  setPlaceId(null)
                  setPlaceName(null)
                }}
                data-testid="travel-edit-place-clear"
                className="min-h-[44px] shrink-0 text-body font-semibold text-accent"
              >
                {TravelCopy.change}
              </button>
            </div>
          ) : (
            <div className="flex flex-col gap-xs">
              <TextField
                label={travelPlaceLabel(reference)}
                placeholder={TravelCopy.searchPlaceholder}
                value={query}
                onChange={setQuery}
                testId="travel-edit-place-query"
                maxLength={MAX_PLACE_QUERY_CHARS}
              />

              {status !== 'idle' && (
                <p
                  data-testid="travel-edit-place-status"
                  role="status"
                  className="text-caption text-ink/72"
                >
                  {status === 'searching' && TravelCopy.searching}
                  {status === 'empty' && TravelCopy.noResults}
                  {status === 'failed' && TravelCopy.searchFailed}
                </p>
              )}

              {status === 'failed' && (
                <button
                  type="button"
                  onClick={() => setAttempt((count) => count + 1)}
                  data-testid="travel-edit-place-retry"
                  className="min-h-[44px] self-start text-body font-bold text-accent"
                >
                  {AppCopy.retry}
                </button>
              )}

              {results.length > 0 && (
                <ul className="flex flex-col gap-xxs" data-testid="travel-edit-place-results">
                  {results.map((suggestion, index) => (
                    <li key={suggestion.place_id}>
                      <button
                        type="button"
                        onClick={() => {
                          setQuery('')
                          setPlaceId(suggestion.place_id)
                          setPlaceName(suggestion.name)
                        }}
                        data-testid={`travel-edit-place-option-${index}`}
                        className="flex min-h-[44px] w-full items-center justify-between gap-sm rounded-field border border-border bg-card px-sm py-xs text-left"
                      >
                        <span className="flex min-w-0 flex-col gap-xxs">
                          <span className="text-body">{suggestion.name}</span>
                          {suggestion.address && (
                            <span className="text-caption text-ink/72">{suggestion.address}</span>
                          )}
                        </span>
                        {/* Distinguishes a tappable candidate from the field above it. */}
                        <ArrowRightIcon className="size-[1.05em] shrink-0 text-accent" />
                      </button>
                    </li>
                  ))}
                </ul>
              )}
            </div>
          ))}

        {/* Why bother: the cost of leaving the place empty is otherwise invisible. */}
        <p
          data-testid="travel-edit-note"
          className="rounded-field bg-green-soft px-sm py-xs text-caption text-ink"
        >
          {needsPlace ? TravelEditCopy.benefit : TravelEditCopy.clearsPlace}
        </p>

        {errorMessage && (
          <InlineErrorView message={errorMessage} onRetry={() => setErrorMessage(null)} />
        )}

        <PrimaryButton
          title={TravelEditCopy.save}
          isLoading={isSaving}
          onClick={() => void submit()}
          testId="save-travel-reference"
        />
        <SecondaryButton
          title={AppCopy.cancel}
          disabled={isSaving}
          onClick={onDismiss}
          testId="cancel-travel-reference"
        />
      </div>
    </BottomSheet>
  )
}
