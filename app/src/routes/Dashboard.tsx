import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import { Empty, Err } from '../components/Chrome'
import { KIND_LABEL, fmt, fmtShort } from '../lib/format'
import { BAD, GOOD, SERIES, WEEK_LABELS, maxAbs, monthLabel, shortDate, weekOfMonth, widthPct } from '../lib/chart'
import type { PeriodSummary } from '../lib/types'

/* One row of v_current_budget — despite the name it covers all history. */
interface Line {
  budget_period_id: number
  period_start: string
  account_name: string
  type_name: string | null
  kind: string
  due_date: string | null
  amount_due: number
  amount_paid: number
  status: string
}

interface MonthRow { month: string; income: number; spending: number; saved: number }

const ALL = 'all'
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']

const yearOf = (iso: string) => iso.slice(0, 4)
const THIS_YEAR = String(new Date().getFullYear())
const THIS_MONTH = String(new Date().getMonth() + 1)
const monthOf = (iso: string) => Number(iso.slice(5, 7))

/* One row of the slim all-years pull the year-on-year card needs. */
interface YearLine { period_start: string; kind: string; amount_due: number; amount_paid: number }

/* PostgREST caps a response; page until a short one comes back. */
async function fetchPaged<T>(cols: string, year: string): Promise<T[]> {
  const size = 1000
  const out: T[] = []
  for (let from = 0; ; from += size) {
    let q = supabase.from('v_current_budget').select(cols).order('period_start')
    if (year !== ALL) q = q.gte('period_start', `${year}-01-01`).lte('period_start', `${year}-12-31`)
    const { data, error } = await q.range(from, from + size - 1)
    if (error) throw new Error(error.message)
    const rows = (data ?? []) as unknown as T[]
    out.push(...rows)
    if (rows.length < size) return out
  }
}

const fetchLines = (year: string) => fetchPaged<Line>(
  'budget_period_id,period_start,account_name,type_name,kind,due_date,amount_due,amount_paid,status',
  year)

/* Year on year needs every year, but only four columns of each row. */
const fetchYearly = () => fetchPaged<YearLine>(
  'period_start,kind,amount_due,amount_paid', ALL)

/* ------------------------------------------------------------------ */

function Card({ title, note, children }: {
  title: string; note?: string; children: React.ReactNode
}) {
  return (
    <section className="border border-rule min-w-0">
      <header className="px-3 pt-3">
        <h3 className="text-[15px]">{title}</h3>
        {note && <p className="text-xs text-ink3 mt-0.5">{note}</p>}
      </header>
      {children}
    </section>
  )
}

function Stat({ label, value, tone }: { label: string; value: string; tone?: 'good' | 'bad' }) {
  return (
    <div className="border border-rule px-3 py-2.5 min-w-0">
      <p className="eyebrow truncate">{label}</p>
      <p className="num text-[19px] mt-1 truncate"
        style={tone ? { color: tone === 'good' ? GOOD : BAD } : undefined}>{value}</p>
    </div>
  )
}

function Legend({ items }: { items: { color: string; label: string }[] }) {
  return (
    <p className="eyebrow px-3 py-2 border-t border-rule normal-case tracking-normal
                  flex flex-wrap gap-x-3 gap-y-1 items-center">
      {items.map((i) => (
        <span key={i.label}>
          <span className="inline-block w-3 h-2 align-middle mr-1"
            style={{ backgroundColor: i.color }} />
          {i.label}
        </span>
      ))}
    </p>
  )
}

function Select({ label, value, onChange, options }: {
  label: string
  value: string
  onChange: (v: string) => void
  options: { value: string; label: string }[]
}) {
  return (
    <label className="flex items-center gap-1.5 min-w-0">
      <span className="eyebrow shrink-0">{label}</span>
      <select className="border border-rule bg-white px-2 py-1 text-xs max-w-[11rem]"
        value={value} onChange={(e) => onChange(e.target.value)}>
        {options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
      </select>
    </label>
  )
}

/* Ranked single-hue bars — one series, so the label carries identity. */
function RankedBars({ rows, total }: { rows: [string, number][]; total: number }) {
  const max = rows[0]?.[1] ?? 1
  return (
    <ul className="mt-2">
      {rows.map(([name, v]) => (
        <li key={name} className="px-3 py-2">
          <div className="flex items-baseline justify-between gap-2">
            <span className="text-[13px] truncate min-w-0">{name}</span>
            <span className="num text-xs text-ink3 shrink-0">
              {fmtShort(v)} · {((v / total) * 100).toFixed(0)}%
            </span>
          </div>
          <div className="mt-1.5 h-2.5 bg-rule/30">
            <div className="h-full" style={{ backgroundColor: SERIES[0], width: widthPct(v, max) }} />
          </div>
        </li>
      ))}
    </ul>
  )
}

/* ------------------------------------------------------------------ *
 * Paychecks against expenses, by which week of the month they fall in.
 * Two measures on one money scale, so one axis and two bars per row.
 * ------------------------------------------------------------------ */
function WeekDueChart({ periods, lines }: { periods: PeriodSummary[]; lines: Line[] }) {
  const pay = [0, 0, 0, 0, 0]
  const due = [0, 0, 0, 0, 0]
  for (const p of periods) {
    if (p.pay_date) pay[weekOfMonth(p.pay_date) - 1] += Number(p.wage_income ?? 0)
  }
  for (const l of lines) {
    if (l.due_date) due[weekOfMonth(l.due_date) - 1] += Number(l.amount_due ?? 0)
  }
  const max = maxAbs([...pay, ...due])
  if (max <= 1) return null

  return (
    <Card title="Paychecks against expenses, by week due"
      note="Which week of the month the money arrives, and which week it leaves.">
      <ul className="mt-2">
        {WEEK_LABELS.map((label, i) => {
          const shortfall = due[i] > pay[i]
          return (
            <li key={label} className="px-3 py-2">
              <div className="flex items-baseline justify-between gap-2">
                <span className="text-[13px]">{label}</span>
                <span className="num text-xs" style={{ color: shortfall ? BAD : GOOD }}>
                  {shortfall ? '−' : '+'}{fmtShort(Math.abs(pay[i] - due[i]))}
                </span>
              </div>
              <div className="mt-1.5 space-y-[3px]">
                <div className="h-2" title={`Paychecks ${fmt(pay[i])}`}
                  style={{ backgroundColor: SERIES[0], width: widthPct(pay[i], max) }} />
                <div className="h-2" title={`Expenses ${fmt(due[i])}`}
                  style={{ backgroundColor: SERIES[1], width: widthPct(due[i], max) }} />
              </div>
            </li>
          )
        })}
      </ul>
      <Legend items={[
        { color: SERIES[0], label: 'Paychecks' },
        { color: SERIES[1], label: 'Expenses due' },
      ]} />
    </Card>
  )
}

/* ------------------------------------------------------------------ *
 * Year on year. The spreadsheet split each year by isSaving, which is
 * what keeps money put aside from reading as money spent — so savings
 * are their own bar rather than being folded into bills.
 *
 * This card ignores the year filter on purpose: a single year compared
 * against itself is not a year-on-year view.
 * ------------------------------------------------------------------ */
function YearOverYearChart({ rows, months }: { rows: YearLine[]; months: MonthRow[] }) {
  const acc = new Map<string, { income: number; spend: number; saved: number }>()
  const at = (y: string) => {
    const cur = acc.get(y) ?? { income: 0, spend: 0, saved: 0 }
    acc.set(y, cur)
    return cur
  }
  for (const m of months) {
    if (m.month) at(yearOf(m.month)).income += Number(m.income ?? 0)
  }
  for (const l of rows) {
    const paid = Number(l.amount_paid || l.amount_due || 0)
    if (!paid) continue
    const y = at(yearOf(l.period_start))
    if (l.kind === 'saving') y.saved += paid
    else y.spend += paid
  }

  const years = [...acc.entries()]
    .filter(([y, v]) => y <= THIS_YEAR && (v.income > 0 || v.spend > 0 || v.saved > 0))
    .sort((a, b) => a[0].localeCompare(b[0]))
  if (years.length === 0) return null

  const max = maxAbs(years.flatMap(([, v]) => [v.income, v.spend, v.saved]))

  return (
    <Card title="Year on year"
      note="Income against bills and expenses, with savings kept separate. Every year, whatever the filter says.">
      <ul className="mt-2">
        {years.map(([y, v]) => {
          const net = v.income - v.spend
          return (
            <li key={y} className="px-3 py-2">
              <div className="flex items-baseline justify-between gap-2">
                <span className="text-[13px] num">{y}</span>
                <span className="num text-xs" style={{ color: net < 0 ? BAD : GOOD }}>
                  {net < 0 ? '−' : '+'}{fmtShort(Math.abs(net))}
                </span>
              </div>
              <div className="mt-1.5 space-y-[3px]">
                <div className="h-2" title={`Income ${fmt(v.income)}`}
                  style={{ backgroundColor: SERIES[0], width: widthPct(v.income, max) }} />
                <div className="h-2" title={`Bills and expenses ${fmt(v.spend)}`}
                  style={{ backgroundColor: SERIES[1], width: widthPct(v.spend, max) }} />
                {v.saved > 0 && (
                  <div className="h-2" title={`Savings ${fmt(v.saved)}`}
                    style={{ backgroundColor: SERIES[2], width: widthPct(v.saved, max) }} />
                )}
              </div>
            </li>
          )
        })}
      </ul>
      <Legend items={[
        { color: SERIES[0], label: 'Income' },
        { color: SERIES[1], label: 'Bills + expenses' },
        { color: SERIES[2], label: 'Savings' },
      ]} />
    </Card>
  )
}

/* ------------------------------------------------------------------ */

export function Dashboard() {
  const [periods, setPeriods] = useState<PeriodSummary[]>([])
  const [months, setMonths] = useState<MonthRow[]>([])
  const [lines, setLines] = useState<Line[]>([])
  const [yearly, setYearly] = useState<YearLine[]>([])
  const [err, setErr] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  const [year, setYear] = useState<string>(ALL)
  // Opens on the month you are in. Clear widens it back to the year.
  const [month, setMonth] = useState<string>(THIS_MONTH)
  const [kind, setKind] = useState<string>(ALL)
  const [category, setCategory] = useState<string>(ALL)
  const [status, setStatus] = useState<string>(ALL)

  // Periods and monthly rollups are small enough to hold in full.
  useEffect(() => {
    void (async () => {
      const [{ data: p, error: pe }, { data: m }] = await Promise.all([
        supabase.from('v_period_summary').select('*').order('period_start'),
        supabase.from('v_income_vs_spending').select('*').order('month'),
      ])
      if (pe) setErr(pe.message)
      const ps = (p ?? []) as PeriodSummary[]
      setPeriods(ps)
      setMonths((m ?? []) as MonthRow[])
      if (ps.length > 0) {
        const ys = [...new Set(ps.map((r) => yearOf(r.period_start)))]
          .filter((y) => y <= THIS_YEAR).sort()
        setYear(ys.includes(THIS_YEAR) ? THIS_YEAR : (ys[ys.length - 1] ?? ALL))
      }
      setLoading(false)
    })()
  }, [])

  // Lines are the big table, so only the selected year is pulled.
  useEffect(() => {
    if (loading) return
    void (async () => {
      try { setLines(await fetchLines(year)) }
      catch (e) { setErr(e instanceof Error ? e.message : String(e)) }
    })()
  }, [year, loading])

  // Year on year is the one card that ignores the year filter, so it gets
  // its own slim pull across every year, once.
  useEffect(() => {
    if (loading) return
    void (async () => {
      try { setYearly(await fetchYearly()) }
      catch (e) { setErr(e instanceof Error ? e.message : String(e)) }
    })()
  }, [loading])

  // generate_budget_periods runs a year forward, so budget_period holds
  // future years with nothing in them. Keep them out of the picker.
  const years = useMemo(
    () => [...new Set(periods.map((p) => yearOf(p.period_start)))]
      .filter((y) => y <= THIS_YEAR).sort().reverse(),
    [periods])

  const categories = useMemo(
    () => [...new Set(lines.map((l) => l.type_name).filter(Boolean) as string[])].sort(),
    [lines])

  /* Year and month scope the whole page. */
  const inScope = (iso: string) =>
    (year === ALL || yearOf(iso) === year) &&
    (month === ALL || monthOf(iso) === Number(month))

  const shownPeriods = periods.filter((p) => inScope(p.period_start))
  const shownMonths = months.filter((m) => inScope(m.month))

  /* Kind, category and status narrow the line-level cards only. */
  const shownLines = lines.filter((l) =>
    inScope(l.period_start) &&
    (kind === ALL || l.kind === kind) &&
    (category === ALL || l.type_name === category) &&
    (status === ALL || (status === 'paid' ? l.status === 'paid' : l.status !== 'paid')))

  const rank = (key: (l: Line) => string) => {
    const by = new Map<string, number>()
    for (const l of shownLines) {
      const k = key(l) || 'Uncategorized'
      by.set(k, (by.get(k) ?? 0) + Number(l.amount_paid || l.amount_due || 0))
    }
    return [...by.entries()].filter(([, v]) => v > 0).sort((a, b) => b[1] - a[1])
  }

  const byCategory = useMemo(() => rank((l) => l.type_name ?? ''), [shownLines])
  const byAccount = useMemo(() => rank((l) => l.account_name), [shownLines])
  const lineTotal = shownLines.reduce((t, l) => t + Number(l.amount_paid || l.amount_due || 0), 0)

  const latest = shownPeriods[shownPeriods.length - 1]
  const filtered = kind !== ALL || category !== ALL || status !== ALL

  const fundParts = [
    { key: 'wage_income' as const, label: 'Paycheck', color: SERIES[0] },
    { key: 'opening_balance' as const, label: 'Carried in', color: SERIES[1] },
    { key: 'from_credit' as const, label: 'From credit', color: SERIES[2] },
    { key: 'from_savings' as const, label: 'From savings', color: SERIES[3] },
  ]
  const fundTotal = (r: PeriodSummary) =>
    fundParts.reduce((t, p) => t + Math.max(0, Number(r[p.key] ?? 0)), 0)

  return (
    <>
      <div className="pt-5 pb-3">
        <h2 className="text-lg font-medium">Dashboard</h2>
        <p className="text-xs text-ink3 mt-0.5">
          {shownPeriods.length} pay period{shownPeriods.length === 1 ? '' : 's'}
          {latest && ` through ${shortDate(latest.period_start)}`}
        </p>
      </div>

      {/* Filters, side by side, wrapping on a narrow screen. */}
      <div className="flex flex-wrap items-center gap-x-4 gap-y-2 pb-4 border-b border-rule">
        <Select label="Year" value={year} onChange={setYear}
          options={[{ value: ALL, label: 'All years' },
                    ...years.map((y) => ({ value: y, label: y }))]} />
        <Select label="Month" value={month} onChange={setMonth}
          options={[{ value: ALL, label: 'All months' },
                    ...MONTHS.map((m, i) => ({ value: String(i + 1), label: m }))]} />
        <Select label="Type" value={kind} onChange={setKind}
          options={[{ value: ALL, label: 'All types' },
                    ...['bill', 'expense', 'debt', 'saving']
                      .map((k) => ({ value: k, label: KIND_LABEL[k] }))]} />
        <Select label="Category" value={category} onChange={setCategory}
          options={[{ value: ALL, label: 'All categories' },
                    ...categories.map((c) => ({ value: c, label: c }))]} />
        <Select label="Status" value={status} onChange={setStatus}
          options={[{ value: ALL, label: 'Any' },
                    { value: 'paid', label: 'Paid' },
                    { value: 'unpaid', label: 'Not paid' }]} />
        {(month !== ALL || filtered) && (
          <button className="btn py-1 text-xs"
            onClick={() => { setMonth(ALL); setKind(ALL); setCategory(ALL); setStatus(ALL) }}>
            Clear
          </button>
        )}
      </div>

      <Err msg={err} />
      {loading && <Empty>Loading…</Empty>}
      {!loading && shownPeriods.length === 0 && <Empty>Nothing in this range.</Empty>}

      {latest && (
        <div className="grid gap-3 grid-cols-2 lg:grid-cols-4 py-5">
          <Stat label="Paycheck" value={fmt(latest.wage_income)} />
          <Stat label="Everything due" value={fmt(latest.total_due)} />
          <Stat label="Left over" value={fmt(latest.balance_on_wages)}
            tone={Number(latest.balance_on_wages) < 0 ? 'bad' : 'good'} />
          <Stat label="Projected balance" value={fmt(latest.projected_balance)}
            tone={Number(latest.projected_balance) < 0 ? 'bad' : undefined} />
        </div>
      )}

      {shownPeriods.length > 0 && (
        <div className="grid gap-4 items-start lg:grid-cols-2">
          {/* Did the paycheck cover it — the difference, plotted directly. */}
          <Card title="Did the paycheck cover it?"
            note="Wages plus what carried in, less everything due. Left of the line is a shortfall.">
            <ul className="mt-2">
              {shownPeriods.slice(-14).map((r) => {
                const v = Number(r.balance_on_wages ?? 0)
                const short = v < 0
                const max = maxAbs(shownPeriods.map((x) => Number(x.balance_on_wages ?? 0)))
                return (
                  <li key={r.budget_period_id} className="px-3 py-2">
                    <div className="flex items-baseline justify-between gap-2">
                      <span className="text-[13px]">{shortDate(r.period_start)}</span>
                      <span className="num text-xs" style={{ color: short ? BAD : GOOD }}>
                        {short ? '−' : '+'}{fmtShort(Math.abs(v))}
                      </span>
                    </div>
                    <div className="relative mt-1.5 h-2.5 bg-rule/30">
                      <div className="absolute inset-y-0 left-1/2 w-px bg-ink3" />
                      <div className="absolute inset-y-0"
                        style={{
                          backgroundColor: short ? BAD : GOOD,
                          width: `calc(${widthPct(v, max)} / 2)`,
                          ...(short ? { right: '50%' } : { left: '50%' }),
                        }} />
                    </div>
                  </li>
                )
              })}
            </ul>
          </Card>

          {/* Where each period's money came from. */}
          <Card title="How each period was funded"
            note="Paycheck first; anything after it is money brought in from somewhere else.">
            <ul className="mt-2">
              {shownPeriods.slice(-14).map((r) => {
                const total = fundTotal(r)
                const max = maxAbs(shownPeriods.map(fundTotal))
                return (
                  <li key={r.budget_period_id} className="px-3 py-2">
                    <div className="flex items-baseline justify-between gap-2">
                      <span className="text-[13px]">{shortDate(r.period_start)}</span>
                      <span className="num text-xs text-ink3 ml-auto">{fmtShort(total)}</span>
                    </div>
                    <div className="mt-1.5 flex gap-[2px] h-2.5" style={{ width: widthPct(total, max) }}>
                      {fundParts.map((p) => {
                        const v = Math.max(0, Number(r[p.key] ?? 0))
                        if (v <= 0) return null
                        return <span key={p.key} title={`${p.label} ${fmt(v)}`}
                          style={{ backgroundColor: p.color, flexGrow: v, flexBasis: 0 }} />
                      })}
                    </div>
                  </li>
                )
              })}
            </ul>
            <Legend items={fundParts.map((p) => ({ color: p.color, label: p.label }))} />
          </Card>

          {/* Line-level: these two answer to every filter. */}
          {byCategory.length > 0 && (
            <Card title="Where it went"
              note={`By category — ${fmt(lineTotal)} across ${shownLines.length} lines.`}>
              <RankedBars rows={byCategory.slice(0, 12)} total={lineTotal} />
            </Card>
          )}

          {byAccount.length > 0 && (
            <Card title="Bills and amount paid"
              note="Biggest accounts in the selection.">
              <RankedBars rows={byAccount.slice(0, 12)} total={lineTotal} />
            </Card>
          )}

          {shownMonths.length > 0 && (
            <Card title="Income against spending"
              note="By month. The figure is what was left over.">
              <ul className="mt-2">
                {shownMonths.slice(-14).map((r) => {
                  const saved = Number(r.saved ?? 0)
                  const max = maxAbs(shownMonths.flatMap((x) =>
                    [Number(x.income), Number(x.spending)]))
                  return (
                    <li key={r.month} className="px-3 py-2">
                      <div className="flex items-baseline justify-between gap-2">
                        <span className="text-[13px]">{monthLabel(r.month)}</span>
                        <span className="num text-xs" style={{ color: saved < 0 ? BAD : GOOD }}>
                          {saved < 0 ? '−' : '+'}{fmtShort(Math.abs(saved))}
                        </span>
                      </div>
                      <div className="mt-1.5 space-y-[3px]">
                        <div className="h-2" title={`Income ${fmt(r.income)}`}
                          style={{ backgroundColor: SERIES[0], width: widthPct(Number(r.income), max) }} />
                        <div className="h-2" title={`Spending ${fmt(r.spending)}`}
                          style={{ backgroundColor: SERIES[1], width: widthPct(Number(r.spending), max) }} />
                      </div>
                    </li>
                  )
                })}
              </ul>
              <Legend items={[{ color: SERIES[0], label: 'Income' },
                              { color: SERIES[1], label: 'Spending' }]} />
            </Card>
          )}

          <WeekDueChart periods={shownPeriods} lines={shownLines} />

          <YearOverYearChart rows={yearly} months={months} />
        </div>
      )}

      {filtered && (
        <p className="text-xs text-ink3 pt-4">
          Type, category and status narrow the two line-level cards. The period
          cards above them are paycheck-level and answer to year and month only.
        </p>
      )}
    </>
  )
}
