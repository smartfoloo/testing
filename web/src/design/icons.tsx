/**
 * Inline SVG stand-ins for the SF Symbols the iOS views reference, so the web build
 * has no icon-font dependency. Each name matches the SF Symbol used in SwiftUI:
 * sparkles, arrow.right, checklist, person.2, slider.horizontal.3, text.bubble,
 * exclamationmark.circle, fork.knife, checkmark, checkmark.seal.fill,
 * square.and.arrow.up, doc.on.doc, qrcode.viewfinder.
 */

interface IconProps {
  className?: string
}

function Svg({ className, children }: IconProps & { children: React.ReactNode }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.9}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
      className={className ?? 'size-[1.15em] shrink-0'}
    >
      {children}
    </svg>
  )
}

export function SparklesIcon(props: IconProps) {
  return (
    <Svg {...props}>
      <path d="M12 3l1.6 4.4L18 9l-4.4 1.6L12 15l-1.6-4.4L6 9l4.4-1.6z" />
      <path d="M18.5 15.5l.7 1.8 1.8.7-1.8.7-.7 1.8-.7-1.8-1.8-.7 1.8-.7z" />
      <path d="M5 15l.6 1.5L7 17l-1.4.5L5 19l-.6-1.5L3 17l1.4-.5z" />
    </Svg>
  )
}

export function ChevronLeftIcon(props: IconProps) {
  return (
    <Svg {...props}>
      <path d="M15 5l-7 7 7 7" strokeWidth={2.2} />
    </Svg>
  )
}

export function ArrowRightIcon(props: IconProps) {
  return (
    <Svg {...props}>
      <path d="M4 12h15" />
      <path d="M13 6l6 6-6 6" />
    </Svg>
  )
}

export function ChecklistIcon(props: IconProps) {
  return (
    <Svg {...props}>
      <path d="M3 6l2 2 3-3" />
      <path d="M3 17l2 2 3-3" />
      <path d="M11 7h10" />
      <path d="M11 18h10" />
    </Svg>
  )
}

export function PeopleIcon(props: IconProps) {
  return (
    <Svg {...props}>
      <circle cx="9" cy="8" r="3.2" />
      <path d="M3.5 20c0-3 2.5-5 5.5-5s5.5 2 5.5 5" />
      <path d="M16 5.5a3.2 3.2 0 010 5.6" />
      <path d="M17.5 15c2 .6 3.5 2.4 3.5 5" />
    </Svg>
  )
}

export function SlidersIcon(props: IconProps) {
  return (
    <Svg {...props}>
      <path d="M3 7h13" />
      <path d="M19 7h2" />
      <circle cx="17" cy="7" r="2" />
      <path d="M3 17h5" />
      <path d="M11 17h10" />
      <circle cx="9.5" cy="17" r="2" />
    </Svg>
  )
}

export function TextBubbleIcon(props: IconProps) {
  return (
    <Svg {...props}>
      <path d="M20 12.5c0 3.6-3.6 6.5-8 6.5-.9 0-1.8-.1-2.6-.35L5 21l1-3.4A6.6 6.6 0 014 12.5C4 8.9 7.6 6 12 6s8 2.9 8 6.5z" />
      <path d="M9 11.5h6" />
      <path d="M9 14.5h4" />
    </Svg>
  )
}

export function ExclamationCircleIcon(props: IconProps) {
  return (
    <Svg {...props}>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M12 8v4.5" />
      <path d="M12 16h.01" />
    </Svg>
  )
}

export function ForkKnifeIcon(props: IconProps) {
  return (
    <Svg {...props}>
      {/* fork: outer tines, middle tine, handle */}
      <path d="M5.5 3v5a2.5 2.5 0 005 0V3" />
      <path d="M8 3v5" />
      <path d="M8 10.5V21" />
      {/* knife: spine plus a tapered blade */}
      <path d="M16.5 21V3" />
      <path d="M16.5 3c2.1 1.9 3.1 4.1 3.1 6.4 0 1.7-1.1 2.9-3.1 2.9" />
    </Svg>
  )
}

export function CheckIcon(props: IconProps) {
  return (
    <Svg {...props}>
      <path d="M4.5 12.5l5 5 10-11" />
    </Svg>
  )
}

export function CheckSealIcon(props: IconProps) {
  return (
    <Svg {...props}>
      <path
        d="M12 2.6l2.2 1.7 2.7-.3 1 2.6 2.4 1.3-.6 2.7.6 2.7-2.4 1.3-1 2.6-2.7-.3L12 21.4l-2.2-1.7-2.7.3-1-2.6L3.7 16l.6-2.7-.6-2.7 2.4-1.3 1-2.6 2.7.3z"
        fill="currentColor"
        stroke="none"
      />
      <path d="M8.5 12.2l2.4 2.4 4.6-5" stroke="var(--color-card)" strokeWidth={2.1} />
    </Svg>
  )
}

export function ShareIcon(props: IconProps) {
  return (
    <Svg {...props}>
      <path d="M12 3v11" />
      <path d="M8 6.5L12 3l4 3.5" />
      <path d="M6 12.5H5a1.5 1.5 0 00-1.5 1.5v5A1.5 1.5 0 005 20.5h14a1.5 1.5 0 001.5-1.5v-5a1.5 1.5 0 00-1.5-1.5h-1" />
    </Svg>
  )
}

export function CopyIcon(props: IconProps) {
  return (
    <Svg {...props}>
      <rect x="9" y="9" width="11" height="11" rx="2.2" />
      <path d="M15 6.5A2.5 2.5 0 0012.5 4H6.5A2.5 2.5 0 004 6.5v6A2.5 2.5 0 006.5 15" />
    </Svg>
  )
}

export function QrViewfinderIcon(props: IconProps) {
  return (
    <Svg {...props}>
      <path d="M3 8.5V5.8A2.8 2.8 0 015.8 3h2.7" />
      <path d="M15.5 3h2.7A2.8 2.8 0 0121 5.8v2.7" />
      <path d="M21 15.5v2.7A2.8 2.8 0 0118.2 21h-2.7" />
      <path d="M8.5 21H5.8A2.8 2.8 0 013 18.2v-2.7" />
      <rect x="7.5" y="7.5" width="4" height="4" rx="0.8" />
      <path d="M14 7.5h2.5V10" />
      <path d="M7.5 14v2.5H10" />
      <path d="M14 16.5h2.5V14" />
    </Svg>
  )
}

/** SwiftUI ProgressView() — an indeterminate circular spinner. */
export function Spinner({ className }: IconProps) {
  return (
    <svg
      viewBox="0 0 24 24"
      className={className ?? 'size-[1.15em] shrink-0 animate-spin'}
      aria-hidden="true"
      focusable="false"
    >
      <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="2.6" opacity="0.25" fill="none" />
      <path
        d="M21 12a9 9 0 00-9-9"
        stroke="currentColor"
        strokeWidth="2.6"
        strokeLinecap="round"
        fill="none"
      />
    </svg>
  )
}
