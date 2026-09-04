/*
 * Chart colours.
 *
 * The app's own palette is a deliberately desaturated ledger green, which
 * is right for the interface and unusable for multi-series charts: put
 * through a categorical check, moss and slate land ΔE 10 apart for normal
 * vision and under 6 under deuteranopia. So anything that needs to tell
 * series apart draws from SERIES instead.
 *
 * Validated on the #FBFCFA surface: lightness band, chroma floor, CVD
 * separation (worst adjacent ΔE 15.9 deutan), normal-vision floor (21.5)
 * and contrast all pass.
 *
 * THE ORDER MATTERS: green sits last precisely because it
 * collides with orange under deuteranopia, and separating them is what
 * clears the check. Assign these in order and never cycle -- a fifth
 * series folds into "Other" instead.
 *
 * The values live in index.css as RGB channels, which is why they are
 * wrapped in rgb() here -- used bare, var(--series-1) resolves to an
 * invalid colour and paints nothing.
 */
// Wrapped in rgb() on purpose: the variables hold space-separated
// channels ("43 108 163") so Tailwind can composite an alpha onto them.
// Used bare, `var(--series-1)` resolves to an invalid colour and paints
// nothing at all.
export const SERIES = [
  'rgb(var(--series-1))', 'rgb(var(--series-2))',
  'rgb(var(--series-3))', 'rgb(var(--series-4))',
] as const

/*
 * Status is a separate job from identity and keeps the app's own colours,
 * so a surplus reads the same here as a paid row does elsewhere. Both
 * always ship with words beside them, never colour alone.
 */
export const GOOD = 'rgb(var(--good))'
export const BAD = 'rgb(var(--bad))'

/** Largest absolute value in a set, for a shared axis. 0 never divides. */
export const maxAbs = (xs: number[]) => Math.max(1, ...xs.map((x) => Math.abs(x)))

/** Clamp to a sane bar width. */
export const widthPct = (v: number, max: number) =>
  `${Math.max(0, Math.min(100, (Math.abs(v) / max) * 100))}%`

/** "Aug 21" from an ISO date, without dragging a date library in. */
export function shortDate(iso: string | null | undefined) {
  if (!iso) return '—'
  const [y, m, d] = iso.split('-').map(Number)
  return new Date(y, m - 1, d).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })
}

/**
 * Which week of the month a date falls in, 1-5 — the buckets the
 * spreadsheet used for "by week due". Days 1-7 are the first week, 8-14
 * the second, and so on, with the 29th onward falling into a short fifth.
 */
export const weekOfMonth = (iso: string) =>
  Math.min(5, Math.floor((Number(iso.slice(8, 10)) - 1) / 7) + 1)

export const WEEK_LABELS = [
  '1st week', '2nd week', '3rd week', '4th week', '5th week',
]

/** "Aug 2025" for month buckets. */
export function monthLabel(iso: string | null | undefined) {
  if (!iso) return '—'
  const [y, m] = iso.split('-').map(Number)
  return new Date(y, m - 1, 1).toLocaleDateString('en-US', { month: 'short', year: 'numeric' })
}
