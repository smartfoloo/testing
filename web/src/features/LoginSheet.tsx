/**
 * Ported from Features/Onboarding/LoginSheet.swift.
 *
 * Login is optional and stays optional: the app runs on the anonymous session
 * `ensureSession()` creates, and this sheet only exists because an anonymous session is
 * unrecoverable — clearing the browser or opening the app on another device loses the
 * event. Both facts are stated on screen (`optionalLogin`, `loginCaveat`) rather than
 * implied, and logging out returns to an anonymous session so nothing stops working.
 *
 * `data-testid`s reproduce the Swift `accessibilityIdentifier`s: login-sheet, login-email,
 * login-password, login-submit, logout.
 */

import { useId, useState } from 'react'
import { useBackend } from '../backend'
import {
  BottomSheet,
  InlineErrorView,
  PrimaryButton,
  SecondaryButton,
} from '../design/components'
import { AppCopy, errorMessage } from '../design/copy'

interface LoginSheetProps {
  /** Non-null while a real account is signed in; drives the signed-in view. */
  currentEmail: string | null
  onDismiss: () => void
  onSignedIn: (email: string | null) => void
  onSignedOut: () => void
}

/**
 * TextField in design/components.tsx is a `type="text"` field by contract, and this is the
 * one screen that needs `type="email"` / `type="password"` (the right iOS keyboard, and a
 * password manager that can actually fill it). Same markup, same tokens, same 48px target,
 * and the font size still comes from the base rule — `max(16px, --text-body)`, which is
 * what stops iOS Safari zooming the page on focus.
 */
function LoginField({
  label,
  type,
  value,
  placeholder,
  autoComplete,
  testId,
  onChange,
}: {
  label: string
  type: 'email' | 'password'
  value: string
  placeholder: string
  autoComplete: 'email' | 'current-password'
  testId: string
  onChange: (value: string) => void
}) {
  const id = useId()
  return (
    <div className="flex flex-col gap-xs">
      <label htmlFor={id} className="text-section">
        {label}
      </label>
      <input
        id={id}
        type={type}
        value={value}
        placeholder={placeholder}
        autoComplete={autoComplete}
        autoCapitalize="none"
        autoCorrect="off"
        spellCheck={false}
        data-testid={testId}
        onChange={(nativeEvent) => onChange(nativeEvent.target.value)}
        className="min-h-[48px] w-full rounded-field border border-border bg-card px-sm text-ink placeholder:text-ink/45"
      />
    </div>
  )
}

export function LoginSheet({
  currentEmail,
  onDismiss,
  onSignedIn,
  onSignedOut,
}: LoginSheetProps) {
  const backend = useBackend()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [isSubmitting, setIsSubmitting] = useState(false)
  const [isSigningOut, setIsSigningOut] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const signIn = async () => {
    // The double-submit guard from LoginSheet.swift: two taps must not start two sign-ins.
    if (isSubmitting) return
    setIsSubmitting(true)
    setError(null)
    try {
      const signedInEmail = await backend.signIn(email.trim(), password)
      setIsSubmitting(false)
      onSignedIn(signedInEmail)
      // The sheet closes on success; on failure it stays open with the error.
      onDismiss()
    } catch (thrown) {
      setError(errorMessage(thrown))
      setIsSubmitting(false)
    }
  }

  const signOut = async () => {
    if (isSigningOut) return
    setIsSigningOut(true)
    setError(null)
    try {
      await backend.signOutToAnonymous()
      setIsSigningOut(false)
      onSignedOut()
      onDismiss()
    } catch (thrown) {
      setError(errorMessage(thrown))
      setIsSigningOut(false)
    }
  }

  return (
    <BottomSheet title={AppCopy.login} isOpen onDismiss={onDismiss}>
      <div data-testid="login-sheet" className="flex flex-col gap-md">
        {currentEmail === null ? (
          <>
            <p className="text-body text-ink/72">{AppCopy.optionalLogin}</p>
            {/* Said before the fields, not after: joining anonymously first is the normal
                case, and the requirements already entered do not follow the new account. */}
            <p className="text-caption text-ink/72">{AppCopy.loginCaveat}</p>
            <LoginField
              label={AppCopy.email}
              type="email"
              value={email}
              placeholder="example@example.com"
              autoComplete="email"
              testId="login-email"
              onChange={setEmail}
            />
            <LoginField
              label={AppCopy.password}
              type="password"
              value={password}
              placeholder="パスワードを入力"
              autoComplete="current-password"
              testId="login-password"
              onChange={setPassword}
            />
            <PrimaryButton
              title={AppCopy.loginSubmit}
              isLoading={isSubmitting}
              // Nothing to submit until both are filled; the address is trimmed first, so
              // whitespace is not a password-shaped secret.
              disabled={email.trim().length === 0 || password.length === 0}
              onClick={() => void signIn()}
              testId="login-submit"
            />
          </>
        ) : (
          <>
            <p className="text-section">{AppCopy.signedIn}</p>
            <p className="text-body text-ink/72">{currentEmail}</p>
            <SecondaryButton
              title={isSigningOut ? AppCopy.loading : AppCopy.logout}
              disabled={isSigningOut}
              onClick={() => void signOut()}
              testId="logout"
            />
          </>
        )}
        {error !== null && <InlineErrorView message={error} onRetry={() => setError(null)} />}
      </div>
    </BottomSheet>
  )
}
