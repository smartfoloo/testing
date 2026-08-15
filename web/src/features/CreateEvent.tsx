/** Ported from Features/Onboarding/CreateEventView.swift. */

import { useEffect, useState } from 'react'
import QRCode from 'qrcode'
import { useBackend } from '../backend'
import { AppCopy, objectiveLabel, travelLabel } from '../design/copy'
import {
  Divider,
  InlineErrorView,
  PrimaryButton,
  SelectionChip,
  TextField,
} from '../design/components'
import { CopyIcon, ShareIcon } from '../design/icons'
import {
  EVENT_OBJECTIVES,
  SELECTABLE_TRAVEL_REFERENCES,
  type EventObjective,
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

          <div className="flex flex-col gap-sm">
            <h3 className="text-section">移動の基準</h3>
            <div className="flex flex-wrap gap-xs">
              {SELECTABLE_TRAVEL_REFERENCES.map((value) => (
                <SelectionChip
                  key={value}
                  title={travelLabel(value)}
                  isSelected={travelReference === value}
                  onClick={() => setTravelReference(value)}
                />
              ))}
            </div>
          </div>

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

function DoneView({ inviteCode, onContinue }: { inviteCode: string; onContinue: () => void }) {
  const [qr, setQr] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    let active = true
    // CIFilter.qrCodeGenerator with correctionLevel "M" in CreateEventView.qrImage.
    QRCode.toDataURL(inviteCode, { errorCorrectionLevel: 'M', margin: 1, scale: 10 })
      .then((url) => {
        if (active) setQr(url)
      })
      .catch(() => {
        if (active) setQr(null)
      })
    return () => {
      active = false
    }
  }, [inviteCode])

  const share = async () => {
    if (navigator.share) {
      try {
        await navigator.share({ text: inviteCode })
        return
      } catch {
        // User dismissed the share sheet, or the gesture was rejected.
      }
    }
    await copy()
  }

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(inviteCode)
      setCopied(true)
      setTimeout(() => setCopied(false), 1800)
    } catch {
      // Clipboard permission denied; the code stays selectable on screen.
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
        このコードを共有して、みんなを招待しましょう。
      </p>

      <div className="flex items-center gap-lg text-accent">
        <button type="button" onClick={share} className="flex min-h-[44px] items-center gap-xs">
          <ShareIcon />
          <span className="text-body">共有する</span>
        </button>
        <button type="button" onClick={copy} className="flex min-h-[44px] items-center gap-xs">
          <CopyIcon />
          <span className="text-body">{copied ? 'コピーしました' : 'コピー'}</span>
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
