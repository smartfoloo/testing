/**
 * Ported from AIKanji/AIKanji/DesignSystem/{Components,StateViews,TabPillBar}.swift.
 * `data-testid` values reproduce the SwiftUI `accessibilityIdentifier`s so the same
 * golden-path assertions can be written against the web build.
 */

import { useEffect, useId, useRef, type ReactNode } from 'react'
import { AppCopy } from './copy'
import {
  ChecklistIcon,
  ChevronLeftIcon,
  ExclamationCircleIcon,
  PeopleIcon,
  SlidersIcon,
  Spinner,
  TextBubbleIcon,
} from './icons'
import type { HomeTab } from '../models/types'
import { cn } from './cn'

/* -------------------------------------------------------------------------- */
/* Buttons                                                                     */
/* -------------------------------------------------------------------------- */

interface PrimaryButtonProps {
  title: string
  icon?: ReactNode
  isLoading?: boolean
  disabled?: boolean
  onClick: () => void
  testId?: string
  className?: string
}

export function PrimaryButton({
  title,
  icon,
  isLoading = false,
  disabled = false,
  onClick,
  testId,
  className,
}: PrimaryButtonProps) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={isLoading || disabled}
      data-testid={testId ?? `primary-${title}`}
      className={cn(
        'flex min-h-[48px] w-full items-center justify-center gap-xs rounded-pill bg-accent px-md',
        'text-body font-bold text-white transition-opacity',
        'active:opacity-80 disabled:opacity-45',
        className,
      )}
    >
      {isLoading ? <Spinner /> : icon}
      <span>{isLoading ? AppCopy.loading : title}</span>
    </button>
  )
}

interface SecondaryButtonProps {
  title: string
  icon?: ReactNode
  disabled?: boolean
  onClick: () => void
  testId?: string
  className?: string
}

export function SecondaryButton({
  title,
  icon,
  disabled = false,
  onClick,
  testId,
  className,
}: SecondaryButtonProps) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      data-testid={testId}
      className={cn(
        // SwiftUI: Capsule().strokeBorder(border, lineWidth: 1.5, dash: [6, 5])
        'flex min-h-[48px] w-full items-center justify-center gap-xs rounded-pill px-md',
        'border-[1.5px] border-dashed border-border bg-card',
        'text-body font-semibold text-ink transition-opacity active:opacity-80 disabled:opacity-45',
        className,
      )}
    >
      {icon}
      <span>{title}</span>
    </button>
  )
}

interface SelectionChipProps {
  title: string
  isSelected: boolean
  onClick: () => void
  testId?: string
}

export function SelectionChip({ title, isSelected, onClick, testId }: SelectionChipProps) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={isSelected}
      data-testid={testId}
      className={cn(
        'min-h-[44px] rounded-pill px-md text-body font-semibold transition-colors',
        isSelected ? 'bg-accent text-white' : 'border border-border bg-card text-ink',
      )}
    >
      {title}
    </button>
  )
}

interface StarterChipProps {
  title: string
  /** AppColors.accentSoft for MUST, AppColors.yellow for WANT. */
  tint: 'accent-soft' | 'yellow'
  onClick: () => void
}

export function StarterChip({ title, tint, onClick }: StarterChipProps) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        'min-h-[44px] rounded-pill px-sm text-caption font-semibold text-ink transition-opacity active:opacity-80',
        tint === 'accent-soft' ? 'bg-accent-soft' : 'bg-yellow',
      )}
    >
      {title}
    </button>
  )
}

/* -------------------------------------------------------------------------- */
/* Containers                                                                  */
/* -------------------------------------------------------------------------- */

export function AppCard({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <div className={cn('card-shadow rounded-card bg-card p-md', className)}>{children}</div>
  )
}

interface StatTileProps {
  value: string
  title: string
  tint: 'card' | 'accent-soft'
  testId?: string
}

export function StatTile({ value, title, tint, testId }: StatTileProps) {
  return (
    <div
      data-testid={testId}
      className={cn(
        'flex w-full flex-col items-start gap-xs rounded-card p-md',
        tint === 'card' ? 'bg-card' : 'bg-accent-soft',
      )}
    >
      <span className="text-display">{value}</span>
      <span className="text-caption text-ink/72">{title}</span>
    </div>
  )
}

/* -------------------------------------------------------------------------- */
/* Bottom sheet                                                                */
/* -------------------------------------------------------------------------- */

interface BottomSheetProps {
  title: string
  isOpen: boolean
  /** Mirrors .interactiveDismissDisabled(_:) — blocks backdrop and Escape dismissal. */
  dismissDisabled?: boolean
  onDismiss: () => void
  children: ReactNode
}

export function BottomSheet({
  title,
  isOpen,
  dismissDisabled = false,
  onDismiss,
  children,
}: BottomSheetProps) {
  const titleId = useId()
  const panelRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!isOpen) return
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && !dismissDisabled) onDismiss()
    }
    document.addEventListener('keydown', onKeyDown)
    const previousOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    panelRef.current?.focus()
    return () => {
      document.removeEventListener('keydown', onKeyDown)
      document.body.style.overflow = previousOverflow
    }
  }, [isOpen, dismissDisabled, onDismiss])

  if (!isOpen) return null

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center">
      <div
        className="absolute inset-0 bg-black/35"
        onClick={() => {
          if (!dismissDisabled) onDismiss()
        }}
        aria-hidden="true"
      />
      <div
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        tabIndex={-1}
        className={cn(
          'safe-b relative flex max-h-[92vh] w-full max-w-[560px] flex-col gap-md overflow-y-auto',
          'rounded-t-sheet bg-background px-lg pt-sm outline-none',
          'motion-safe:animate-[matomeshi-sheet-in_.24s_ease-out]',
        )}
      >
        {/* Capsule().fill(ink.opacity(0.2)).frame(width: 42, height: 5) */}
        <div className="mx-auto h-[5px] w-[42px] shrink-0 rounded-pill bg-ink/20" />
        <h2 id={titleId} className="text-title">
          {title}
        </h2>
        <div className="pb-lg">{children}</div>
      </div>
    </div>
  )
}

/* -------------------------------------------------------------------------- */
/* Tab bar                                                                     */
/* -------------------------------------------------------------------------- */

interface TabPillBarProps {
  selection: HomeTab
  showsOrganizer: boolean
  onSelect: (tab: HomeTab) => void
}

export function TabPillBar({ selection, showsOrganizer, onSelect }: TabPillBarProps) {
  const tabs: Array<{ tab: HomeTab; title: string; icon: ReactNode }> = [
    { tab: 'requirements', title: AppCopy.homeRequirements, icon: <ChecklistIcon /> },
    { tab: 'group', title: AppCopy.homeGroup, icon: <PeopleIcon /> },
  ]
  if (showsOrganizer) {
    tabs.push({ tab: 'organizer', title: AppCopy.homeOrganizer, icon: <SlidersIcon /> })
  }

  return (
    <div className="px-lg" role="tablist">
      <div className="card-shadow flex gap-xs rounded-pill bg-card p-[6px]">
        {tabs.map(({ tab, title, icon }) => {
          const isSelected = selection === tab
          return (
            <button
              key={tab}
              type="button"
              role="tab"
              aria-selected={isSelected}
              aria-label={title}
              data-testid={`tab-${tab}`}
              onClick={() => onSelect(tab)}
              className={cn(
                'flex min-h-[44px] flex-1 items-center justify-center gap-xxs rounded-pill px-xxs',
                'text-caption font-semibold transition-colors',
                isSelected ? 'bg-accent text-white' : 'text-ink',
              )}
            >
              {icon}
              <span className="truncate">{title}</span>
            </button>
          )
        })}
      </div>
    </div>
  )
}

/* -------------------------------------------------------------------------- */
/* State views                                                                 */
/* -------------------------------------------------------------------------- */

export function LoadingStateView({ title }: { title: string }) {
  return (
    <div className="relative rounded-card bg-card p-md" aria-label={title} role="status">
      <div className="skeleton flex flex-col gap-sm">
        <div className="h-[18px] rounded-lg bg-ink/8" />
        <div className="h-[14px] rounded-lg bg-ink/6" />
        <div className="h-[14px] rounded-lg bg-ink/6" />
      </div>
      {/* .overlay(alignment: .bottomLeading) in StateViews.swift */}
      <span className="absolute bottom-md left-md text-caption text-ink/72">{title}</span>
    </div>
  )
}

export function EmptyStateView({ title, message }: { title: string; message: string }) {
  return (
    <div className="flex w-full flex-col items-center gap-sm py-xxl">
      <TextBubbleIcon className="size-[28px] text-accent" />
      <p className="text-section">{title}</p>
      <p className="text-center text-body text-ink/72">{message}</p>
    </div>
  )
}

export function InlineErrorView({ message, onRetry }: { message: string; onRetry: () => void }) {
  return (
    <div className="flex flex-col items-start gap-sm rounded-card bg-accent-soft p-md" role="alert">
      <p className="flex items-start gap-xs text-body text-ink">
        <ExclamationCircleIcon className="mt-[3px] size-[1.05em] shrink-0" />
        <span>{message}</span>
      </p>
      <button
        type="button"
        onClick={onRetry}
        className="min-h-[44px] text-body font-bold text-accent"
      >
        {AppCopy.retry}
      </button>
    </div>
  )
}

/* -------------------------------------------------------------------------- */
/* Chrome                                                                      */
/* -------------------------------------------------------------------------- */

/** .navigationTitle(_:) with .navigationBarTitleDisplayMode(.inline). */
export function NavBar({ title, onBack }: { title: string; onBack?: () => void }) {
  return (
    <header className="safe-t sticky top-0 z-30 bg-background/92 backdrop-blur-md">
      <div className="relative flex min-h-[44px] items-center justify-center px-lg">
        {onBack && (
          <button
            type="button"
            onClick={onBack}
            aria-label="戻る"
            data-testid="nav-back"
            className="absolute left-[10px] flex size-[44px] items-center justify-center text-accent"
          >
            <ChevronLeftIcon className="size-[22px]" />
          </button>
        )}
        <h1 className="truncate px-[44px] text-section">{title}</h1>
      </div>
    </header>
  )
}

export function Divider() {
  return <hr className="h-px border-0 bg-border" />
}

/* -------------------------------------------------------------------------- */
/* Fields                                                                      */
/* -------------------------------------------------------------------------- */

interface TextFieldProps {
  label: string
  placeholder?: string
  value: string
  onChange: (value: string) => void
  testId?: string
  inputMode?: 'text' | 'numeric'
  mono?: boolean
  autoCapitalize?: 'none' | 'sentences'
  maxLength?: number
}

export function TextField({
  label,
  placeholder,
  value,
  onChange,
  testId,
  inputMode = 'text',
  mono = false,
  autoCapitalize = 'sentences',
  maxLength,
}: TextFieldProps) {
  const id = useId()
  return (
    <div className="flex flex-col gap-xs">
      <label htmlFor={id} className="text-section">
        {label}
      </label>
      <input
        id={id}
        type="text"
        value={value}
        placeholder={placeholder}
        inputMode={inputMode}
        maxLength={maxLength}
        autoCapitalize={autoCapitalize}
        autoCorrect={autoCapitalize === 'none' ? 'off' : 'on'}
        spellCheck={autoCapitalize !== 'none'}
        data-testid={testId}
        onChange={(nativeEvent) => onChange(nativeEvent.target.value)}
        className={cn(
          'min-h-[48px] w-full rounded-field border border-border bg-card px-sm text-ink',
          'placeholder:text-ink/45',
          mono && 'font-mono tracking-[0.14em]',
        )}
      />
    </div>
  )
}

interface TextAreaProps {
  value: string
  placeholder: string
  onChange: (value: string) => void
  testId?: string
}

/** TextEditor + the .overlay placeholder trick from ConstraintEntryView. */
export function TextArea({ value, placeholder, onChange, testId }: TextAreaProps) {
  return (
    <div className="relative">
      <textarea
        value={value}
        rows={3}
        data-testid={testId}
        aria-label={placeholder}
        onChange={(nativeEvent) => onChange(nativeEvent.target.value)}
        className={cn(
          'min-h-[84px] w-full resize-y rounded-field border border-border bg-card p-sm text-ink',
          'placeholder:text-ink/55',
        )}
        placeholder={placeholder}
      />
    </div>
  )
}

/* -------------------------------------------------------------------------- */
/* Alert                                                                       */
/* -------------------------------------------------------------------------- */

interface AlertProps {
  title: string
  message: string
  isOpen: boolean
  dismissTitle?: string
  onDismiss: () => void
}

/** SwiftUI .alert(_:isPresented:) with a single dismiss button. */
export function Alert({ title, message, isOpen, dismissTitle = '閉じる', onDismiss }: AlertProps) {
  useEffect(() => {
    if (!isOpen) return
    const onKeyDown = (nativeEvent: KeyboardEvent) => {
      if (nativeEvent.key === 'Escape') onDismiss()
    }
    document.addEventListener('keydown', onKeyDown)
    return () => document.removeEventListener('keydown', onKeyDown)
  }, [isOpen, onDismiss])

  if (!isOpen) return null
  return (
    <div className="fixed inset-0 z-60 flex items-center justify-center p-lg">
      <div className="absolute inset-0 bg-black/35" onClick={onDismiss} aria-hidden="true" />
      <div
        role="alertdialog"
        aria-modal="true"
        className="relative w-full max-w-[320px] overflow-hidden rounded-card bg-card text-center"
      >
        <div className="flex flex-col gap-xs p-lg">
          <p className="text-section">{title}</p>
          <p className="text-caption text-ink/72">{message}</p>
        </div>
        <button
          type="button"
          onClick={onDismiss}
          className="min-h-[48px] w-full border-t border-border text-body font-bold text-accent"
        >
          {dismissTitle}
        </button>
      </div>
    </div>
  )
}
