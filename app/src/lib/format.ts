const money = new Intl.NumberFormat('en-US', {
  style: 'currency', currency: 'USD', minimumFractionDigits: 2,
})

export const fmt = (n: number | null | undefined) => money.format(Number(n ?? 0))

export const fmtShort = (n: number | null | undefined) =>
  money.format(Number(n ?? 0)).replace(/\.00$/, '')

export function fmtDate(iso: string | null | undefined) {
  if (!iso) return '—'
  const [y, m, d] = iso.split('-').map(Number)
  return new Date(y, m - 1, d).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })
}

export function daysUntil(iso: string) {
  const [y, m, d] = iso.split('-').map(Number)
  const then = new Date(y, m - 1, d)
  const now = new Date()
  now.setHours(0, 0, 0, 0)
  return Math.round((then.getTime() - now.getTime()) / 86_400_000)
}

export function urgencyOf(due: string, status: string) {
  if (status === 'paid') return 'paid' as const
  const d = daysUntil(due)
  if (d < 0) return 'overdue' as const
  if (d <= 3) return 'soon' as const
  return 'upcoming' as const
}

export const KIND_LABEL: Record<string, string> = {
  bill: 'Bills', expense: 'Expenses', debt: 'Debt payments', saving: 'Savings',
}
