/** Ported from Features/Onboarding/EventHomeView.swift. */

import { useEffect, useState } from 'react'
import { useBackend } from '../backend'
import { AppCopy, errorMessage as toMessage } from '../design/copy'
import { Alert, TabPillBar } from '../design/components'
import { ConstraintEntry } from './ConstraintEntry'
import { GroupFeed } from './GroupFeed'
import { NegotiationWatcher } from './NegotiationConsent'
import { OrganizerDashboard } from './OrganizerDashboard'
import type { EventDecision, HomeTab, ParticipantRole } from '../models/types'

interface EventHomeProps {
  eventId: string
  participantId: string
  decision: EventDecision | null
  chosenRestaurantName: string | null
  onDecisionLoaded: (decision: EventDecision, restaurantName: string | null) => void
  onRoleLoaded: (role: ParticipantRole) => void
  onOpenRecommendations: (runId: string) => void
}

export function EventHome({
  eventId,
  participantId,
  decision,
  chosenRestaurantName,
  onDecisionLoaded,
  onRoleLoaded,
  onOpenRecommendations,
}: EventHomeProps) {
  const backend = useBackend()
  const [role, setRole] = useState<ParticipantRole | null>(null)
  const [selectedTab, setSelectedTab] = useState<HomeTab>('requirements')
  const [decisionError, setDecisionError] = useState<string | null>(null)

  useEffect(() => {
    let active = true
    void (async () => {
      try {
        const loadedRole = await backend.role(participantId)
        if (!active) return
        setRole(loadedRole)
        onRoleLoaded(loadedRole)

        const loadedDecision = await backend.decision(eventId)
        if (!active) return
        const name = loadedDecision.chosen_place_id
          ? await backend.restaurantName(loadedDecision.chosen_place_id)
          : null
        if (!active) return
        onDecisionLoaded(loadedDecision, name)
      } catch (error) {
        if (active) setDecisionError(toMessage(error))
      }
    })()
    return () => {
      active = false
    }
    // onDecisionLoaded / onRoleLoaded are stable callbacks owned by App.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [backend, eventId, participantId])

  const isOrganizer = role === 'organizer'

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      {/* .overlay(alignment: .top) — the group's confirmed decision */}
      {decision?.chosen_place_id && (
        <div className="pointer-events-none flex justify-center pt-xs">
          <span
            data-testid="chosen-banner"
            className="rounded-pill bg-yellow px-md py-xs text-caption font-bold text-ink"
          >
            {chosenRestaurantName ? `${AppCopy.chosen}：${chosenRestaurantName}` : AppCopy.chosen}
          </span>
        </div>
      )}

      <NegotiationWatcher participantId={participantId} />

      <div className="min-h-0 flex-1 overflow-y-auto">
        {selectedTab === 'requirements' && (
          <ConstraintEntry eventId={eventId} participantId={participantId} />
        )}
        {selectedTab === 'group' && <GroupFeed eventId={eventId} />}
        {selectedTab === 'organizer' && (
          <OrganizerDashboard
            eventId={eventId}
            decision={decision}
            chosenRestaurantName={chosenRestaurantName}
            onOpenRecommendations={onOpenRecommendations}
          />
        )}
      </div>

      <div className="safe-b py-sm">
        <TabPillBar
          selection={selectedTab}
          showsOrganizer={isOrganizer}
          onSelect={setSelectedTab}
        />
      </div>

      <Alert
        title="読み込みに失敗しました"
        message={decisionError ?? AppCopy.networkError}
        isOpen={decisionError !== null}
        onDismiss={() => setDecisionError(null)}
      />
    </div>
  )
}
