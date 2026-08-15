/**
 * Ported from App/AIKanjiApp.swift plus the NavigationStack wiring the SwiftUI views get
 * for free. Screens already on the stack stay mounted (hidden) so their state survives a
 * push, the way a NavigationStack keeps parent views alive.
 */

import { useCallback, useEffect, useState } from 'react'
import { BackendProvider, useBackend } from './backend'
import { Alert, NavBar } from './design/components'
import { cn } from './design/cn'
import { AppCopy } from './design/copy'
import { CreateEvent } from './features/CreateEvent'
import { EventHome } from './features/EventHome'
import { JoinEvent } from './features/JoinEvent'
import { Recommendations } from './features/Recommendations'
import { Welcome } from './features/Welcome'
import { inviteCodeFromLocation } from './models/invite'
import type { EventDecision, ParticipantRole } from './models/types'

type Route =
  | { name: 'welcome' }
  | { name: 'create' }
  | { name: 'join'; initialCode?: string }
  | { name: 'home'; eventId: string; participantId: string; inviteCode: string }
  | { name: 'recommendations'; runId: string }

/**
 * An invite link (`?code=xxxxxx`) opens straight into the join screen with the code
 * filled in, so the QR and the shared link behave the same way.
 */
function initialStack(): Route[] {
  const code = inviteCodeFromLocation()
  return code ? [{ name: 'welcome' }, { name: 'join', initialCode: code }] : [{ name: 'welcome' }]
}

function useSystemTheme(): void {
  useEffect(() => {
    const query = window.matchMedia('(prefers-color-scheme: dark)')
    const apply = () => document.documentElement.classList.toggle('dark', query.matches)
    apply()
    query.addEventListener('change', apply)
    return () => query.removeEventListener('change', apply)
  }, [])
}

function Shell() {
  const backend = useBackend()
  const [stack, setStack] = useState<Route[]>(initialStack)
  const [authError, setAuthError] = useState<string | null>(null)
  const [role, setRole] = useState<ParticipantRole | null>(null)
  const [decision, setDecision] = useState<EventDecision | null>(null)
  const [chosenRestaurantName, setChosenRestaurantName] = useState<string | null>(null)

  useSystemTheme()

  // Supa.ensureSession() — anonymous sign-in, once per launch.
  useEffect(() => {
    void backend.ensureSession().catch((error: unknown) => {
      setAuthError(error instanceof Error ? error.message : String(error))
    })
  }, [backend])

  // Browser/gesture back is the single source of truth for popping.
  useEffect(() => {
    const onPopState = () => setStack((current) => (current.length > 1 ? current.slice(0, -1) : current))
    window.addEventListener('popstate', onPopState)
    return () => window.removeEventListener('popstate', onPopState)
  }, [])

  const push = useCallback((route: Route) => {
    setStack((current) => {
      window.history.pushState({ depth: current.length + 1 }, '')
      return [...current, route]
    })
  }, [])

  const goBack = useCallback(() => window.history.back(), [])

  const onDecisionLoaded = useCallback((loaded: EventDecision, name: string | null) => {
    setDecision(loaded)
    setChosenRestaurantName(name)
  }, [])

  const onRoleLoaded = useCallback((loaded: ParticipantRole) => setRole(loaded), [])

  const home = stack.find((route): route is Extract<Route, { name: 'home' }> => route.name === 'home')

  const titleFor = (route: Route): string | null => {
    switch (route.name) {
      case 'welcome':
        return null
      case 'create':
        return '集まりを作る'
      case 'join':
        return AppCopy.join
      case 'home':
        return route.inviteCode ? `集まり ${route.inviteCode}` : '集まり'
      case 'recommendations':
        return AppCopy.recommendations
    }
  }

  const screenFor = (route: Route) => {
    switch (route.name) {
      case 'welcome':
        return (
          <Welcome
            onCreate={() => push({ name: 'create' })}
            onJoin={() => push({ name: 'join' })}
          />
        )
      case 'create':
        return (
          <CreateEvent
            onContinue={({ eventId, participantId, inviteCode }) =>
              push({ name: 'home', eventId, participantId, inviteCode })
            }
          />
        )
      case 'join':
        return (
          <JoinEvent
            initialCode={route.initialCode}
            onContinue={({ eventId, participantId, inviteCode }) =>
              push({ name: 'home', eventId, participantId, inviteCode })
            }
          />
        )
      case 'home':
        return (
          <EventHome
            eventId={route.eventId}
            participantId={route.participantId}
            decision={decision}
            chosenRestaurantName={chosenRestaurantName}
            onDecisionLoaded={onDecisionLoaded}
            onRoleLoaded={onRoleLoaded}
            onOpenRecommendations={(runId) => push({ name: 'recommendations', runId })}
          />
        )
      case 'recommendations':
        if (!home) return null
        return (
          <Recommendations
            runId={route.runId}
            eventId={home.eventId}
            isOrganizer={role === 'organizer'}
            decision={decision}
            onChosen={(result) => {
              setDecision(result)
              if (result.chosen_place_id) {
                void backend
                  .restaurantName(result.chosen_place_id)
                  .then(setChosenRestaurantName)
                  .catch(() => setChosenRestaurantName(null))
              }
            }}
          />
        )
    }
  }

  return (
    <>
      {stack.map((route, index) => {
        const isTop = index === stack.length - 1
        const title = titleFor(route)
        return (
          <div
            key={`${route.name}-${index}`}
            className={cn('flex min-h-dvh flex-col bg-background', !isTop && 'hidden')}
            aria-hidden={!isTop}
          >
            {title && <NavBar title={title} onBack={index > 0 ? goBack : undefined} />}
            <main className="flex min-h-0 flex-1 flex-col">{screenFor(route)}</main>
          </div>
        )
      })}

      <Alert
        title="ログインに失敗しました"
        message={authError ?? ''}
        isOpen={authError !== null}
        onDismiss={() => setAuthError(null)}
      />
    </>
  )
}

export default function App() {
  return (
    <BackendProvider>
      <Shell />
    </BackendProvider>
  )
}
