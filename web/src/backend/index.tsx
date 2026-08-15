// oxlint-disable react/only-export-components -- a React context module necessarily
// exports both its provider component and the hook that reads it.
import { createContext, useContext, useMemo, type ReactNode } from 'react'
import { MockBackend } from './mock'
import { SupabaseBackend } from './supabase'
import type { Backend } from './types'

export type { Backend } from './types'
export { MockBackend } from './mock'

/**
 * Uses the real Supabase project when credentials are present, otherwise falls back to
 * the in-browser fixture so the app is runnable with no setup. Copy `.env.example` to
 * `.env.local` and fill both values to switch over.
 */
export function createBackend(): Backend {
  const url = import.meta.env.VITE_SUPABASE_URL?.trim()
  const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY?.trim()
  if (url && anonKey) {
    return new SupabaseBackend(url.startsWith('http') ? url : `https://${url}`, anonKey)
  }
  return new MockBackend()
}

const BackendContext = createContext<Backend | null>(null)

export function BackendProvider({ children }: { children: ReactNode }) {
  const backend = useMemo(() => createBackend(), [])
  return <BackendContext.Provider value={backend}>{children}</BackendContext.Provider>
}

export function useBackend(): Backend {
  const backend = useContext(BackendContext)
  if (!backend) throw new Error('useBackend must be used inside BackendProvider')
  return backend
}
