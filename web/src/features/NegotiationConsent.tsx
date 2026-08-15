/** Ported from Features/Negotiation/NegotiationConsentView.swift (sheet + watcher). */

import { useEffect, useState } from 'react'
import { useBackend } from '../backend'
import { AppCopy, errorMessage as toMessage } from '../design/copy'
import {
  AppCard,
  BottomSheet,
  InlineErrorView,
  PrimaryButton,
  SecondaryButton,
} from '../design/components'
import { negotiationImpact, negotiationQuestion } from '../models/format'
import type { PendingNegotiation } from '../models/types'

interface NegotiationConsentProps {
  negotiation: PendingNegotiation | null
  onRespond: (accept: boolean) => Promise<void>
  onDismiss: () => void
}

export function NegotiationConsent({
  negotiation,
  onRespond,
  onDismiss,
}: NegotiationConsentProps) {
  const [isSubmitting, setIsSubmitting] = useState(false)
  const [errorMessage, setErrorMessage] = useState<string | null>(null)

  useEffect(() => {
    if (negotiation) {
      setIsSubmitting(false)
      setErrorMessage(null)
    }
  }, [negotiation])

  const respond = async (accept: boolean) => {
    if (isSubmitting) return
    setIsSubmitting(true)
    try {
      await onRespond(accept)
    } catch (error) {
      setErrorMessage(toMessage(error))
    }
    setIsSubmitting(false)
  }

  return (
    <BottomSheet
      title="ちょっとした確認"
      isOpen={negotiation !== null}
      dismissDisabled={isSubmitting}
      onDismiss={onDismiss}
    >
      {negotiation && (
        <div className="flex flex-col gap-lg">
          <p className="text-section">{negotiationQuestion(negotiation)}</p>
          <p className="text-body font-bold text-accent">{negotiationImpact(negotiation)}</p>

          {errorMessage && (
            <InlineErrorView message={errorMessage} onRetry={() => setErrorMessage(null)} />
          )}

          <AppCard>
            <div className="flex flex-col gap-xs">
              <p className="text-caption font-bold">あなたの元の要望</p>
              <p className="text-body">{negotiation.participant_constraints.raw_text}</p>
            </div>
          </AppCard>

          <PrimaryButton
            title={AppCopy.negotiationAccept}
            isLoading={isSubmitting}
            onClick={() => void respond(true)}
            testId="negotiation-accept"
          />
          <SecondaryButton
            title={AppCopy.negotiationDecline}
            disabled={isSubmitting}
            onClick={() => void respond(false)}
            testId="negotiation-decline"
          />

          <p className="text-caption text-ink/72">
            回答はあなたの希望にだけ反映され、誰が何を選んだかは他の参加者には表示されません。
          </p>
        </div>
      )}
    </BottomSheet>
  )
}

const POLL_INTERVAL_MS = 5000

/**
 * Ported from the NegotiationWatcher view modifier: polls for a proposal aimed at this
 * participant and presents the consent sheet. RLS means only the targeted participant
 * ever sees it.
 */
export function NegotiationWatcher({ participantId }: { participantId: string }) {
  const backend = useBackend()
  const [pending, setPending] = useState<PendingNegotiation | null>(null)
  const [errorMessage, setErrorMessage] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    let timer: number | undefined

    const poll = async () => {
      if (cancelled) return
      try {
        // Only look while nothing is on screen, matching `if pending == nil`.
        setPending((current) => current)
        const found = await backend.pendingNegotiation(participantId)
        if (cancelled) return
        setPending((current) => current ?? found)
        setErrorMessage(null)
      } catch {
        if (!cancelled) setErrorMessage(AppCopy.networkError)
      }
      if (!cancelled) timer = window.setTimeout(() => void poll(), POLL_INTERVAL_MS)
    }

    void poll()
    return () => {
      cancelled = true
      if (timer) window.clearTimeout(timer)
    }
  }, [backend, participantId])

  return (
    <>
      {errorMessage && (
        <div className="px-md pt-xs">
          <InlineErrorView message={errorMessage} onRetry={() => setErrorMessage(null)} />
        </div>
      )}
      <NegotiationConsent
        negotiation={pending}
        onDismiss={() => setPending(null)}
        onRespond={async (accept) => {
          if (!pending) return
          await backend.respondNegotiation(pending.id, accept)
          setPending(null)
        }}
      />
    </>
  )
}
