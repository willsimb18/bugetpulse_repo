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

/*
 * The dot's meaning in words. Same four states urgencyOf() returns, but
 * said rather than coloured — the dot alone is meaning carried by hue,
 * which nobody can decode on first sight and colourblind readers cannot
 * decode at all.
 */
export function urgencyLabel(due: string, status: string) {
  if (status === 'paid') return 'Paid'
  if (status === 'partial') return 'Part paid'
  const d = daysUntil(due)
  if (d < 0) return `${Math.abs(d)} day${Math.abs(d) === 1 ? '' : 's'} late`
  if (d === 0) return 'Due today'
  if (d === 1) return 'Due tomorrow'
  return `In ${d} days`
}

export const URGENCY_LEGEND: { key: string; dot: string; label: string }[] = [
  { key: 'overdue',  dot: 'bg-rust', label: 'Overdue' },
  { key: 'soon',     dot: 'bg-amber', label: 'Due within 3 days' },
  { key: 'upcoming', dot: 'bg-rule', label: 'Later' },
  { key: 'paid',     dot: 'bg-moss', label: 'Paid' },
]

export const KIND_LABEL: Record<string, string> = {
  bill: 'Bills', expense: 'Expenses', debt: 'Debt payments', saving: 'Savings',
}

// account.debt_detail.debt_type — the enum the import maps Finance's
// DebtType.TypeName onto. Shown as "sub type" in the old spreadsheet.
export const DEBT_TYPE_LABEL: Record<string, string> = {
  credit_card: 'Credit cards',
  auto_loan: 'Auto loans',
  student_loan: 'Student loans',
  line_of_credit: 'Lines of credit',
  personal_loan: 'Personal loans',
  mortgage: 'Mortgage',
  other: 'Other',
}

// Fixed display order, so a group never changes position as balances move.
export const DEBT_TYPE_ORDER = [
  'credit_card', 'line_of_credit', 'auto_loan', 'student_loan',
  'personal_loan', 'mortgage', 'other',
]
