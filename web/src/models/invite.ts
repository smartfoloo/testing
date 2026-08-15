/**
 * Ported from JoinEventView.extractInviteCode(from:). Accepts a bare code or a URL
 * carrying it as `?code=` or as the last path component, then clamps to the 6 lowercase
 * characters fn_generate_invite_code emits.
 */
export function extractInviteCode(payload: string): string {
  const trimmed = payload.trim()
  try {
    const url = new URL(trimmed)
    if (url.protocol) {
      const fromQuery = url.searchParams.get('code')
      const fromPath = url.pathname.split('/').filter(Boolean).pop()
      const candidate = fromQuery ?? fromPath ?? trimmed
      return candidate.toLowerCase().slice(0, 6)
    }
  } catch {
    // Not a URL, fall through to the bare-code path.
  }
  return trimmed.toLowerCase().slice(0, 6)
}
