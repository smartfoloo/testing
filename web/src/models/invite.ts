/** Invite code helpers. Codes are the 6 lowercase characters fn_generate_invite_code emits. */

/**
 * PRD §3 requires inviting participants "by link/QR", not just a code. The link carries
 * the code as `?code=`, which `extractInviteCode` below already understands, so a scanned
 * QR and a tapped link resolve identically.
 */
export function buildInviteUrl(code: string, origin: string = window.location.origin): string {
  const url = new URL(origin)
  url.pathname = '/'
  url.search = ''
  url.searchParams.set('code', code)
  return url.toString()
}

/** Reads a prefilled invite code out of the current URL, for link-based joins. */
export function inviteCodeFromLocation(search: string = window.location.search): string | null {
  const code = new URLSearchParams(search).get('code')
  if (!code) return null
  const normalized = code.toLowerCase().slice(0, 6)
  return normalized.length === 6 ? normalized : null
}

/**
 * Ported from JoinEventView.extractInviteCode(from:). Accepts a bare code or a URL
 * carrying it as `?code=` or as the last path component.
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
