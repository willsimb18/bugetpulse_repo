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

// account.debt_detail.debt_type — the enum the import maps Finance's
// DebtType.TypeName onto. Shown as "sub type" in the old spreadsheet.
export const DEBT_TYPE_LABEL: Record<string, string> = {
  credit_card: 'Credit cards',
  auto_loan: 'Auto loans',
  student_loan: 'Student loans',
  personal_loan: 'Personal loans',
  mortgage: 'Mortgage',
  other: 'Other',
}

// Fixed display order, so a group never changes position as balances move.
export const DEBT_TYPE_ORDER = [
  'credit_card', 'auto_loan', 'student_loan', 'personal_loan', 'mortgage', 'other',
]
