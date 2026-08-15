/** Ported from Features/Onboarding/CreateEventView.swift. */

import { useEffect, useState } from 'react'
import QRCode from 'qrcode'
import { useBackend } from '../backend'
import { AppCopy, TravelCopy, objectiveLabel, travelLabel, travelPlaceLabel } from '../design/copy'
import {
  AppCard,
  Divider,
  InlineErrorView,
  PrimaryButton,
  SelectionChip,
  TextField,
} from '../design/components'
import { ArrowRightIcon, CopyIcon, ShareIcon } from '../design/icons'
import { buildInviteUrl } from '../models/invite'
import {
  EVENT_OBJECTIVES,
  TRAVEL_REFERENCES,
  type EventObjective,
  type PlaceSuggestion,
  type TravelReference,
} from '../models/types'

interface CreateEventProps {
  onContinue: (args: { eventId: string; participantId: string; inviteCode: string }) => void
}

export function CreateEvent({ onContinue }: CreateEventProps) {
  const backend = useBackend()
  const [name, setName] = useState('')
  const [displayName, setDisplayName] = useState('')
  const [objective, setObjective] = useState<EventObjective>('balanced')
  const [travelReference, setTravelReference] = useState<TravelReference>('office')
  const [travelPlace, setTravelPlace] = useState<PlaceSuggestion | null>(null)
  const [inviteCode, setInviteCode] = useState<string | null>(null)
  const [created, setCreated] = useState<{ eventId: string; participantId: string } | null>(null)
  const [isSubmitting, setIsSubmitting] = useState(false)
  const [errorMessage, setErrorMessage] = useState<string | null>(null)

  const create = async () => {
    if (isSubmitting) return
    setIsSubmitting(true)
    setErrorMessage(null)
    try {
      const event = await backend.createEvent({
        name: name.trim(),
        displayName: displayName.trim(),
        travelReference,
        // The organizer is a participant too, so their origin is only real if
        // they picked a place. Null is a valid answer: the backend reports them
        // as unresolved instead of inventing a location.
        travelReferencePlaceId: travelPlace?.place_id ?? null,
        objective,
      })
      setCreated({ eventId: event.event_id, participantId: event.participant_id })
      setInviteCode(event.invite_code)
    } catch {
      setErrorMessage(AppCopy.networkError)
    }
    setIsSubmitting(false)
  }

  return (
    <div className="safe-b flex flex-col gap-xl px-lg pb-xxl pt-md">
      {inviteCode && created ? (
        <DoneView inviteCode={inviteCode} onContinue={() => onContinue({ ...created, inviteCode })} />
      ) : (
        <div className="flex flex-col gap-xl">
          <div className="flex flex-col gap-xs">
            <h2 className="text-title">どんな集まりですか？</h2>
            <TextField
              label=""
              placeholder="例：忘年会"
              value={name}
              onChange={setName}
              testId="event-name"
            />
          </div>

          <div className="flex flex-col gap-sm">
            <h3 className="text-section">目的</h3>
            <div className="flex flex-wrap gap-xs">
              {EVENT_OBJECTIVES.map((value) => (
                <SelectionChip
                  key={value}
                  title={objectiveLabel(value)}
                  isSelected={objective === value}
                  onClick={() => setObjective(value)}
                />
              ))}
            </div>
          </div>

          <Divider />

          <TextField
            label="あなたの名前"
            placeholder="例：田中"
            value={displayName}
            onChange={setDisplayName}
            testId="display-name"
          />

          <TravelReferenceField
            reference={travelReference}
            place={travelPlace}
            onChange={(next) => {
              setTravelReference(next.reference)
              setTravelPlace(next.place)
            }}
            testIdPrefix="travel"
          />

          <PrimaryButton
            title="集まりを作成"
            isLoading={isSubmitting}
            disabled={name.trim().length === 0 || displayName.trim().length === 0}
            onClick={create}
            testId="create-submit"
          />
        </div>
      )}

      {errorMessage && <InlineErrorView message={errorMessage} onRetry={create} />}
    </div>
  )
}

/* -------------------------------------------------------------------------- */
/* Travel reference                                                            */
/* -------------------------------------------------------------------------- */

/** Long enough that a burst of typing is one lookup, short enough to feel live. */
const SEARCH_DEBOUNCE_MS = 350
/** Matches the Edge Function's own minimum, so a too-short query never leaves the device. */
const MIN_QUERY_CHARS = 2
const MAX_QUERY_CHARS = 120

interface TravelReferenceSelection {
  reference: TravelReference
  place: PlaceSuggestion | null
}

interface TravelReferenceFieldProps extends TravelReferenceSelection {
  onChange: (next: TravelReferenceSelection) => void
  /** Both onboarding screens render this, so their testids stay distinguishable. */
  testIdPrefix: string
}

/**
 * 移動の基準 — the category AND the place it stands for.
 *
 * `participants.travel_reference` is a CHECK-constrained UI category, so a participant
 * who only answers "会社" gives the recommendation engine nothing to measure travel
 * from: it used to geocode the literal word and quietly score everyone against a
 * fictional origin. The place id collected here is the real origin.
 *
 * Shared by CreateEvent and JoinEvent rather than living in the design system, which
 * is a 1:1 port of the iOS component library — this is product logic, not a primitive.
 */
export function TravelReferenceField({
  reference,
  place,
  onChange,
  testIdPrefix,
}: TravelReferenceFieldProps) {
  const backend = useBackend()
  const [query, setQuery] = useState('')
  const [results, setResults] = useState<PlaceSuggestion[]>([])
  const [status, setStatus] = useState<'idle' | 'searching' | 'empty' | 'failed'>('idle')
  /** Bumped by 「もう一度試す」 so a retry re-runs the effect for an unchanged query. */
  const [attempt, setAttempt] = useState(0)

  // どこでも is a real answer, not a missing one: no travel constraint, no place.
  const needsPlace = reference !== 'doesnt_matter'
  const trimmed = query.trim()
  const isSearching = needsPlace && place === null && trimmed.length >= MIN_QUERY_CHARS

  useEffect(() => {
    if (!isSearching) {
      setResults([])
      setStatus('idle')
      return
    }
    // One provider call per pause in typing, never one per keystroke: this runs on
    // every change, but only the last timer of a burst survives the cleanup.
    let active = true
    setStatus('searching')
    const timer = setTimeout(() => {
      void (async () => {
        try {
          const found = await backend.searchPlaces(trimmed)
          if (!active) return
          setResults(found)
          setStatus(found.length === 0 ? 'empty' : 'idle')
        } catch {
          // A dead provider must not look like "no such place".
          if (!active) return
          setResults([])
          setStatus('failed')
        }
      })()
    }, SEARCH_DEBOUNCE_MS)
    return () => {
      // Also drops the in-flight answer, so a slow early request cannot overwrite
      // the results of a later, narrower query.
      active = false
      clearTimeout(timer)
    }
  }, [backend, isSearching, trimmed, attempt])

  const selectReference = (next: TravelReference) => {
    setQuery('')
    // どこでも carries no location by definition; the other three keep the place so
    // relabelling 会社 as 駅 does not throw away a correct origin.
    onChange({ reference: next, place: next === 'doesnt_matter' ? null : place })
  }

  const note = needsPlace ? TravelCopy.missingPlace : TravelCopy.unconstrained

  return (
    <section className="flex flex-col gap-sm">
      <h3 className="text-section">{TravelCopy.sectionTitle}</h3>
      <p className="text-caption text-ink/72">{TravelCopy.sectionHelp}</p>

      <div className="flex flex-wrap gap-xs">
        {TRAVEL_REFERENCES.map((value) => (
          <SelectionChip
            key={value}
            title={travelLabel(value)}
            isSelected={reference === value}
            onClick={() => selectReference(value)}
            testId={`${testIdPrefix}-reference-${value}`}
          />
        ))}
      </div>

      {needsPlace &&
        (place ? (
          <AppCard className="flex items-center justify-between gap-sm">
            <div
              data-testid={`${testIdPrefix}-place-selected`}
              className="flex min-w-0 flex-col gap-xxs"
            >
              <span className="text-body font-semibold">{place.name}</span>
              {place.address && <span className="text-caption text-ink/72">{place.address}</span>}
            </div>
            <button
              type="button"
              onClick={() => onChange({ reference, place: null })}
              data-testid={`${testIdPrefix}-place-clear`}
              className="min-h-[44px] shrink-0 text-body font-semibold text-accent"
            >
              {TravelCopy.change}
            </button>
          </AppCard>
        ) : (
          <div className="flex flex-col gap-xs">
            <TextField
              label={travelPlaceLabel(reference)}
              placeholder={TravelCopy.searchPlaceholder}
              value={query}
              onChange={setQuery}
              testId={`${testIdPrefix}-place-query`}
              maxLength={MAX_QUERY_CHARS}
            />

            {status !== 'idle' && (
              <p
                data-testid={`${testIdPrefix}-place-status`}
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
                data-testid={`${testIdPrefix}-place-retry`}
                className="min-h-[44px] self-start text-body font-bold text-accent"
              >
                {AppCopy.retry}
              </button>
            )}

            {results.length > 0 && (
              <ul className="flex flex-col gap-xxs" data-testid={`${testIdPrefix}-place-results`}>
                {results.map((suggestion, index) => (
                  <li key={suggestion.place_id}>
                    <button
                      type="button"
                      onClick={() => {
                        setQuery('')
                        onChange({ reference, place: suggestion })
                      }}
                      data-testid={`${testIdPrefix}-place-option-${index}`}
                      className="flex min-h-[44px] w-full items-center justify-between gap-sm rounded-field border border-border bg-card px-sm py-xs text-left"
                    >
                      <span className="flex min-w-0 flex-col gap-xxs">
                        <span className="text-body">{suggestion.name}</span>
                        {suggestion.address && (
                          <span className="text-caption text-ink/72">{suggestion.address}</span>
                        )}
                      </span>
                      {/* Distinguishes a tappable candidate from the text field above it. */}
                      <ArrowRightIcon className="size-[1.05em] shrink-0 text-accent" />
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </div>
        ))}

      {/* Skipping the place is allowed, but never silent: travel fairness is the
          product's whole "no one carries a disproportionate burden" promise. */}
      {(place === null || !needsPlace) && (
        <p
          data-testid={`${testIdPrefix}-place-note`}
          className="rounded-field bg-green-soft px-sm py-xs text-caption text-ink"
        >
          {note}
        </p>
      )}
    </section>
  )
}

function DoneView({ inviteCode, onContinue }: { inviteCode: string; onContinue: () => void }) {
  const [qr, setQr] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)
  // PRD §3: invite "by link/QR". The QR encodes the link so scanning it opens the join
  // flow with the code already filled in, rather than yielding a bare code to retype.
  const inviteUrl = buildInviteUrl(inviteCode)

  useEffect(() => {
    let active = true
    // CIFilter.qrCodeGenerator with correctionLevel "M" in CreateEventView.qrImage.
    QRCode.toDataURL(inviteUrl, { errorCorrectionLevel: 'M', margin: 1, scale: 8 })
      .then((url) => {
        if (active) setQr(url)
      })
      .catch(() => {
        if (active) setQr(null)
      })
    return () => {
      active = false
    }
  }, [inviteUrl])

  const share = async () => {
    if (navigator.share) {
      try {
        await navigator.share({
          title: AppCopy.appName,
          text: `${AppCopy.appName}に参加してください（招待コード: ${inviteCode}）`,
          url: inviteUrl,
        })
        return
      } catch {
        // User dismissed the share sheet, or the gesture was rejected.
      }
    }
    await copy()
  }

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(inviteUrl)
      setCopied(true)
      setTimeout(() => setCopied(false), 1800)
    } catch {
      // Clipboard permission denied; the link stays selectable on screen.
    }
  }

  return (
    <div className="flex flex-col items-center gap-lg">
      <h2 className="text-title">招待コード</h2>

      <p
        data-testid="inviteCode"
        className="w-full select-all text-center font-mono text-display tracking-[0.3em] text-accent"
      >
        {inviteCode}
      </p>

      {qr && (
        <img
          src={qr}
          alt="招待コードのQRコード"
          data-testid="inviteQRCode"
          width={190}
          height={190}
          className="w-[190px] max-w-full rounded-sheet bg-card p-md [image-rendering:pixelated]"
        />
      )}

      <p className="text-center text-body text-ink/72">
        リンクかQRコードを共有して、みんなを招待しましょう。
      </p>

      <p
        data-testid="inviteLink"
        className="w-full select-all break-all rounded-field bg-card px-sm py-xs text-center font-mono text-small text-ink/72"
      >
        {inviteUrl}
      </p>

      <div className="flex items-center gap-lg text-accent">
        <button
          type="button"
          onClick={share}
          data-testid="share-invite"
          className="flex min-h-[44px] items-center gap-xs"
        >
          <ShareIcon />
          <span className="text-body">共有する</span>
        </button>
        <button
          type="button"
          onClick={copy}
          data-testid="copy-invite"
          className="flex min-h-[44px] items-center gap-xs"
        >
          <CopyIcon />
          <span className="text-body">{copied ? 'コピーしました' : 'リンクをコピー'}</span>
        </button>
      </div>

      <button
        type="button"
        onClick={onContinue}
        data-testid="continue-event"
        className="min-h-[48px] w-full rounded-pill bg-accent text-body font-bold text-white active:opacity-80"
      >
        {AppCopy.continueAction}
      </button>
    </div>
  )
}
