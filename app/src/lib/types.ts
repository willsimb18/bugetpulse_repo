export type AccountKind = 'bill' | 'debt' | 'saving' | 'expense'
export type LineStatus = 'scheduled' | 'paid' | 'partial' | 'skipped'
export type AmountMode = 'carry_forward' | 'fixed' | 'percent_of_income'
export type Role = 'owner' | 'member'

export interface Profile {
  id: string
  household_id: string
  display_name: string
  role: Role
}

export interface BudgetPeriod {
  id: number
  period_start: string
  period_end: string
  pay_date: string
  label: string | null
  is_closed: boolean
  opening_balance: number
}

export interface Funding {
  id: number
  budget_period_id: number
  received_on: string
  kind: string
  amount: number
  notes: string | null
  source_account: string | null
  source_kind: string | null
}

export interface PeriodSummary {
  budget_period_id: number
  period_start: string
  period_end: string
  pay_date: string
  label: string | null
  net_income: number
  wage_income: number
  from_savings: number
  from_credit: number
  bonus_income: number
  other_funding: number
  balance_on_wages: number
  total_due: number
  total_paid: number
  remaining_due: number
  bills_due: number
  expenses_due: number
  debts_due: number
  savings_due: number
  projected_balance: number
  actual_balance: number
  line_count: number
  paid_count: number
}

export interface BudgetLine {
  id: number
  budget_period_id: number
  account_id: number | null
  name: string
  category_id: number | null
  kind: AccountKind
  due_date: string
  amount_due: number
  amount_paid: number
  amount_overridden: boolean
  status: LineStatus
  paid_on: string | null
  paid_by: string | null
  funds_held: boolean
  is_manual: boolean
}

export interface AccountAdmin {
  id: number
  name: string
  kind: AccountKind
  frequency: string
  default_amount: number
  due_day: number | null
  is_always_due: boolean
  is_active: boolean
  amount_mode: AmountMode
  amount_percent: number | null
  amount_set_on: string
  type_name: string | null
  sub_type_name: string | null
  last_paid_on: string | null
  last_paid_amount: number | null
  open_lines: number
}

export interface DebtStatus {
  id: number
  name: string
  debt_type: string
  credit_limit: number | null
  apr: number | null
  minimum_payment: number | null
  owner_name: string | null
  current_balance: number | null
  balance_as_of: string | null
  available_credit: number | null
  paid_to_date: number | null
  previous_balance: number | null
  previous_as_of: string | null
  change_since_last: number | null
  utilization: number | null
  paid_off_pct: number | null
  avalanche_rank: number
  snowball_rank: number
}

export interface IncomeRow {
  id: number
  earner: string | null
  received_on: string
  kind: string
  hours: number | null
  gross: number
  taxes: number
  net: number
}

export interface WageRow {
  earner: string
  effective_from: string
  hourly_rate: number | null
  annualized: number | null
  rate_change: number | null
  pct_increase: number | null
  note: string | null
}
