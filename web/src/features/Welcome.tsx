/** Ported from Features/Onboarding/WelcomeView.swift. */

import { useEffect, useState } from 'react'
import { useBackend } from '../backend'
import { AppCopy } from '../design/copy'
import { LoginSheet } from './LoginSheet'

interface WelcomeProps {
  onCreate: () => void
  onJoin: () => void
}

export function Welcome({ onCreate, onJoin }: WelcomeProps) {
  const backend = useBackend()
  const [isLoginPresented, setIsLoginPresented] = useState(false)
  const [signedInEmail, setSignedInEmail] = useState<string | null>(null)

  // WelcomeView's `.task { signedInEmail = await Supa.currentEmail() }`. Null for an
  // anonymous session, which is the normal state — creating and joining never need this.
  useEffect(() => {
    let cancelled = false
    void backend
      .currentEmail()
      .then((email) => {
        if (!cancelled) setSignedInEmail(email)
      })
      .catch(() => {
        // A session that cannot be read is not a login; the app runs anonymously anyway.
        if (!cancelled) setSignedInEmail(null)
      })
    return () => {
      cancelled = true
    }
  }, [backend])

  return (
    <div className="relative flex min-h-dvh flex-col overflow-hidden bg-background">
      {/* The two decorative circles from WelcomeView's ZStack */}
      <div
        aria-hidden="true"
        className="pointer-events-none absolute size-[220px] rounded-full bg-accent-soft"
        style={{ top: -110, left: '50%', transform: 'translateX(calc(-50% + 150px)) translateY(-20%)' }}
      />
      <div
        aria-hidden="true"
        className="pointer-events-none absolute size-[170px] rounded-full bg-green-soft"
        style={{ bottom: -60, left: '50%', transform: 'translateX(calc(-50% - 170px))' }}
      />

      <div className="safe-b relative flex flex-1 flex-col items-center justify-center gap-xl px-xl py-lg">
        <div className="flex flex-col items-center gap-sm">
          <h1 className="text-display text-ink">{AppCopy.appName}</h1>
          <p className="text-caption font-bold text-accent">みんなの予定を、ひとつに</p>
        </div>

        <p className="max-w-[28ch] text-center text-body font-medium text-ink">{AppCopy.tagline}</p>

        <div className="flex w-full max-w-[420px] flex-col gap-sm">
          <button
            type="button"
            onClick={onCreate}
            data-testid="create-event"
            className="min-h-[48px] w-full rounded-pill bg-accent text-body font-bold text-white active:opacity-80"
          >
            {AppCopy.create}
          </button>
          <button
            type="button"
            onClick={onJoin}
            data-testid="join-event"
            className="min-h-[48px] w-full rounded-pill border-[1.5px] border-dashed border-border bg-card text-body font-semibold text-ink active:opacity-80"
          >
            {AppCopy.join}
          </button>
        </div>

        {/*
          The optional-login affordance from WelcomeView: a plain accent button, the caption
          that says it is optional, and — once signed in — the address underneath, so the
          answer to 「this session is recoverable」 is visible without opening the sheet.
        */}
        <div className="flex flex-col items-center gap-xs">
          <button
            type="button"
            onClick={() => setIsLoginPresented(true)}
            data-testid="login"
            className="min-h-[44px] px-sm text-body font-semibold text-accent active:opacity-80"
          >
            {AppCopy.login}
          </button>
          <p className="max-w-[30ch] text-center text-caption text-ink/72">
            {AppCopy.optionalLogin}
          </p>
          {signedInEmail !== null && (
            <p data-testid="signed-in-email" className="text-center text-caption text-ink/72">
              {signedInEmail}
            </p>
          )}
        </div>

        {/*
          Not part of the iOS design — the only affordance added for the web build, so a
          reviewer running without Supabase credentials knows the data is the seed.sql
          fixture and can reach the demo event. Safe to delete once wired to a project.
        */}
        {backend.mode === 'mock' && (
          <p className="max-w-[32ch] text-center text-small text-ink/55">
            デモデータで動作中です。招待コード <span className="font-mono">demo01</span>{' '}
            で5人の集まりに参加できます。
          </p>
        )}
      </div>

      {/*
        `.sheet(isPresented:)`: mounted only while presented, so each presentation starts
        with empty fields and no stale error, the way @State does on iOS.
      */}
      {isLoginPresented && (
        <LoginSheet
          currentEmail={signedInEmail}
          onDismiss={() => setIsLoginPresented(false)}
          onSignedIn={setSignedInEmail}
          onSignedOut={() => setSignedInEmail(null)}
        />
      )}
    </div>
  )
}
