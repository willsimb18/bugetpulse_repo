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

/*
 * The schedule in words: what "Due On" shows for an account.
 *
 * The shape of the answer depends on the cadence — monthly bills carry a
 * day of the month, weekly and biweekly ones an anchor date they count
 * from, per_paycheck none at all — so a single column has to say which
 * kind of thing it is looking at, not just print a number.
 */
export function dueOnLabel(a: {
  kind?: string
  frequency: string
  due_day: number | null
  due_day_2?: number | null
  due_month?: number | null
  anchor_date: string | null
  is_always_due: boolean
}) {
  // Expenses and savings have no due date to speak of — an expense is
  // decided period by period and a savings contribution goes in when the
  // paycheck does. Printing an anchor date for either implies a deadline
  // that does not exist.
  if (a.kind === 'expense' || a.kind === 'saving') return 'n/a'
  // always_due, biweekly and per_paycheck are the same cadence said three
  // ways: one line, every pay period. Three different labels for it read
  // as three different schedules.
  if (a.is_always_due) return 'Every pay period'
  const ord = (d: number) => {
    const s = ['th', 'st', 'nd', 'rd'][(d % 100 - 20) % 10] ?? ['th', 'st', 'nd', 'rd'][d % 100] ?? 'th'
    return `${d}${s}`
  }
  switch (a.frequency) {
    case 'per_paycheck':
      return 'Every pay period'
    case 'semimonthly':
      return a.due_day && a.due_day_2
        ? `${ord(a.due_day)} & ${ord(a.due_day_2)}`
        : a.due_day ? ord(a.due_day) : '—'
    case 'annual':
      if (a.due_month && a.due_day) {
        const m = new Date(2000, a.due_month - 1, 1)
          .toLocaleDateString('en-US', { month: 'short' })
        return `${m} ${a.due_day}`
      }
      return a.due_day ? ord(a.due_day) : '—'
    case 'biweekly':
      return 'Every pay period'
    case 'weekly':
    case 'one_time':
      return a.anchor_date ? `From ${fmtDate(a.anchor_date)}` : '—'
    default:
      return a.due_day ? ord(a.due_day) : '—'
  }
}

/** Which field an account's schedule is actually edited through. */
export const scheduleField = (frequency: string): 'due_day' | 'anchor_date' | 'none' =>
  frequency === 'per_paycheck' ? 'none'
    : ['weekly', 'biweekly', 'one_time'].includes(frequency) ? 'anchor_date'
    : 'due_day'

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
