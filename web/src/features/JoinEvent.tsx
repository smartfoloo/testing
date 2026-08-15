/** Ported from Features/Onboarding/JoinEventView.swift. */

import { useEffect, useRef, useState } from 'react'
import jsQR from 'jsqr'
import { useBackend } from '../backend'
import { AppCopy } from '../design/copy'
import { Divider, InlineErrorView, PrimaryButton, TextField } from '../design/components'
import { QrViewfinderIcon } from '../design/icons'
import { extractInviteCode } from '../models/invite'
import type { PlaceSuggestion, TravelReference } from '../models/types'
// The 移動の基準 picker is shared with the other onboarding screen; it lives there
// rather than in the design system because it is product logic, not a primitive.
import { TravelReferenceField } from './CreateEvent'

interface JoinEventProps {
  /** Prefilled when the participant arrived via an invite link (`?code=`). */
  initialCode?: string
  onContinue: (args: { eventId: string; participantId: string; inviteCode: string }) => void
}

export function JoinEvent({ initialCode, onContinue }: JoinEventProps) {
  const backend = useBackend()
  const [inviteCode, setInviteCode] = useState(initialCode ?? '')
  const [displayName, setDisplayName] = useState('')
  const [travelReference, setTravelReference] = useState<TravelReference>('office')
  const [travelPlace, setTravelPlace] = useState<PlaceSuggestion | null>(null)
  const [isScanning, setIsScanning] = useState(false)
  const [isSubmitting, setIsSubmitting] = useState(false)
  const [joined, setJoined] = useState<{ eventId: string; participantId: string } | null>(null)
  const [errorMessage, setErrorMessage] = useState<string | null>(null)

  const canSubmit = inviteCode.trim().length === 6 && displayName.trim().length > 0

  const join = async () => {
    if (isSubmitting) return
    setIsSubmitting(true)
    setErrorMessage(null)
    try {
      const participantId = await backend.joinEvent({
        inviteCode: inviteCode.trim(),
        displayName: displayName.trim(),
        travelReference,
        // Null when the participant skipped the place, or chose どこでも: the
        // backend then leaves them out of the origins instead of guessing one.
        travelReferencePlaceId: travelPlace?.place_id ?? null,
      })
      const event = await backend.event(inviteCode.trim())
      setJoined({ eventId: event.id, participantId })
    } catch {
      setErrorMessage(AppCopy.networkError)
    }
    setIsSubmitting(false)
  }

  return (
    <div className="safe-b flex flex-col gap-xl px-lg pb-xxl pt-md">
      <div className="flex flex-col gap-xs">
        <TextField
          label="招待コード"
          placeholder="6桁のコード"
          value={inviteCode}
          // JoinEventView clamps to 6 lowercase characters on every change.
          onChange={(value) => setInviteCode(value.toLowerCase().slice(0, 6))}
          testId="invite-code"
          autoCapitalize="none"
          mono
          maxLength={6}
        />
        <button
          type="button"
          onClick={() => setIsScanning(true)}
          data-testid="scan-qr"
          className="flex min-h-[44px] items-center gap-xs self-start text-accent"
        >
          <QrViewfinderIcon />
          <span className="text-body">QRコードを読み取る</span>
        </button>
      </div>

      <Divider />

      <TextField
        label="あなたの名前"
        placeholder="例：佐藤"
        value={displayName}
        onChange={setDisplayName}
        testId="join-display-name"
      />

      <TravelReferenceField
        reference={travelReference}
        place={travelPlace}
        onChange={(next) => {
          setTravelReference(next.reference)
          setTravelPlace(next.place)
        }}
        testIdPrefix="join-travel"
      />

      <PrimaryButton
        title="参加する"
        isLoading={isSubmitting}
        disabled={!canSubmit}
        onClick={join}
        testId="join-submit"
      />

      {joined && (
        <button
          type="button"
          data-testid="continue-event"
          onClick={() => onContinue({ ...joined, inviteCode: inviteCode.trim() })}
          className="min-h-[48px] w-full rounded-pill border border-border bg-card text-body font-semibold text-ink"
        >
          {AppCopy.continueAction}
        </button>
      )}

      {errorMessage && <InlineErrorView message={errorMessage} onRetry={join} />}

      {isScanning && (
        <QRScanner
          onScan={(scanned) => {
            setInviteCode(extractInviteCode(scanned))
            setIsScanning(false)
          }}
          onCancel={() => setIsScanning(false)}
        />
      )}
    </div>
  )
}

/**
 * Web stand-in for VisionKit's DataScannerViewController: getUserMedia plus a jsQR scan
 * loop over frames painted into an offscreen canvas.
 */
function QRScanner({
  onScan,
  onCancel,
}: {
  onScan: (payload: string) => void
  onCancel: () => void
}) {
  const videoRef = useRef<HTMLVideoElement>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let stream: MediaStream | null = null
    let frame = 0
    let stopped = false
    const canvas = document.createElement('canvas')
    const context = canvas.getContext('2d', { willReadFrequently: true })

    const tick = () => {
      if (stopped) return
      const video = videoRef.current
      if (video && context && video.readyState === video.HAVE_ENOUGH_DATA) {
        canvas.width = video.videoWidth
        canvas.height = video.videoHeight
        context.drawImage(video, 0, 0, canvas.width, canvas.height)
        const image = context.getImageData(0, 0, canvas.width, canvas.height)
        const found = jsQR(image.data, image.width, image.height, {
          inversionAttempts: 'dontInvert',
        })
        if (found?.data) {
          stopped = true
          onScan(found.data)
          return
        }
      }
      frame = requestAnimationFrame(tick)
    }

    navigator.mediaDevices
      ?.getUserMedia({ video: { facingMode: 'environment' } })
      .then((granted) => {
        if (stopped) {
          granted.getTracks().forEach((track) => track.stop())
          return
        }
        stream = granted
        if (videoRef.current) {
          videoRef.current.srcObject = granted
          void videoRef.current.play()
        }
        frame = requestAnimationFrame(tick)
      })
      .catch(() => {
        setError('カメラを使用できません。コードを手で入力してください。')
      })

    return () => {
      stopped = true
      cancelAnimationFrame(frame)
      stream?.getTracks().forEach((track) => track.stop())
    }
  }, [onScan])

  return (
    <div className="fixed inset-0 z-50 flex flex-col bg-black">
      <video
        ref={videoRef}
        playsInline
        muted
        className="size-full flex-1 object-cover"
        aria-label="QRコードをカメラに向けてください"
      />
      {/* Viewfinder cut-out, mirroring isHighlightingEnabled on the native scanner */}
      <div className="pointer-events-none absolute inset-0 flex items-center justify-center">
        <div className="size-[62vw] max-w-[280px] rounded-sheet border-[3px] border-white/85" />
      </div>
      {error && (
        <p className="absolute inset-x-lg top-[18%] rounded-card bg-card p-md text-center text-body text-ink">
          {error}
        </p>
      )}
      <button
        type="button"
        onClick={onCancel}
        className="safe-b absolute inset-x-0 bottom-0 min-h-[64px] bg-black/60 text-body font-bold text-white"
      >
        {AppCopy.cancel}
      </button>
    </div>
  )
}
