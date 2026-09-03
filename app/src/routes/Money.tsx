import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { Empty, Err } from '../components/Chrome'
import { fmt, fmtShort } from '../lib/format'
import { BAD, GOOD, SERIES, maxAbs, monthLabel, shortDate, widthPct } from '../lib/chart'
import type { PeriodSummary } from '../lib/types'

/* v_category_spend, aggregated across the periods on screen. */
interface CategorySpend {
  budget_period_id: number
  type_name: string
  budgeted: number
  spent: number
}

/* v_income_vs_spending */
interface MonthRow {
  month: string
  income: number
  spending: number
  saved: number
}

const PERIODS = 12

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

function Stat({ label, value, tone }: {
  label: string; value: string; tone?: 'good' | 'bad'
}) {
  return (
    <div className="border border-rule px-3 py-2.5 min-w-0">
      <p className="eyebrow truncate">{label}</p>
      <p
        className="num text-[19px] mt-1 truncate"
        style={tone ? { color: tone === 'good' ? GOOD : BAD } : undefined}
      >
        {value}
      </p>
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

/* ------------------------------------------------------------------ *
 * Where each period's money came from.
 * Excel: "Paycheck vs balance from last paycheck vs pull from savings".
 * ------------------------------------------------------------------ */
function FundingChart({ rows }: { rows: PeriodSummary[] }) {
  const parts = [
    { key: 'wage_income' as const, label: 'Paycheck', color: SERIES[0] },
    { key: 'opening_balance' as const, label: 'Carried in', color: SERIES[1] },
    { key: 'from_credit' as const, label: 'From credit', color: SERIES[2] },
    { key: 'from_savings' as const, label: 'From savings', color: SERIES[3] },
  ]
  const totalOf = (r: PeriodSummary) =>
    parts.reduce((t, p) => t + Math.max(0, Number(r[p.key] ?? 0)), 0)
  const max = maxAbs(rows.map(totalOf))

  return (
    <Card title="How each period was funded"
      note="Paycheck first; anything after it is money brought in from somewhere else.">
      <ul className="mt-2">
        {rows.map((r) => {
          const total = totalOf(r)
          return (
            <li key={r.budget_period_id} className="px-3 py-2">
              <div className="flex items-baseline justify-between gap-2">
                <span className="text-[13px]">{shortDate(r.period_start)}</span>
                <span className="num text-xs text-ink3">{fmtShort(total)}</span>
              </div>
              {/* 2px gaps so adjacent segments never blend into one another. */}
              <div className="mt-1.5 flex gap-[2px] h-2.5"
                style={{ width: widthPct(total, max) }}>
                {parts.map((p) => {
                  const v = Math.max(0, Number(r[p.key] ?? 0))
                  if (v <= 0) return null
                  return (
                    <span key={p.key} title={`${p.label} ${fmt(v)}`}
                      style={{ backgroundColor: p.color, flexGrow: v, flexBasis: 0 }} />
                  )
                })}
              </div>
            </li>
          )
        })}
      </ul>
      <Legend items={parts.map((p) => ({ color: p.color, label: p.label }))} />
    </Card>
  )
}

/* ------------------------------------------------------------------ *
 * Did the paycheck cover the period?
 * Excel drew paycheck and expenses as two bars; the answer people want is
 * the difference, so this plots that directly around a zero line.
 * ------------------------------------------------------------------ */
function CoverageChart({ rows }: { rows: PeriodSummary[] }) {
  const vals = rows.map((r) => Number(r.balance_on_wages ?? 0))
  const max = maxAbs(vals)

  return (
    <Card title="Did the paycheck cover it?"
      note="Wages plus what carried in, less everything due. Left of the line is a shortfall.">
      <ul className="mt-2">
        {rows.map((r) => {
          const v = Number(r.balance_on_wages ?? 0)
          const short = v < 0
          return (
            <li key={r.budget_period_id} className="px-3 py-2">
              <div className="flex items-baseline justify-between gap-2">
                <span className="text-[13px]">{shortDate(r.period_start)}</span>
                <span className="num text-xs" style={{ color: short ? BAD : GOOD }}>
                  {short ? '−' : '+'}{fmtShort(Math.abs(v))}
                </span>
              </div>
              {/* Zero line down the middle; bars grow out from it. */}
              <div className="relative mt-1.5 h-2.5 bg-rule/30">
                <div className="absolute inset-y-0 left-1/2 w-px bg-ink3" />
                <div
                  className="absolute inset-y-0"
                  style={{
                    backgroundColor: short ? BAD : GOOD,
                    width: `calc(${widthPct(v, max)} / 2)`,
                    ...(short ? { right: '50%' } : { left: '50%' }),
                  }}
                />
              </div>
              <p className="text-[11px] mt-1 text-ink3">
                <span className="num">{fmtShort(r.wage_income)}</span> in ·{' '}
                <span className="num">{fmtShort(r.total_due)}</span> due
                {short && <span style={{ color: BAD }}> · short</span>}
              </p>
            </li>
          )
        })}
      </ul>
    </Card>
  )
}

/* ------------------------------------------------------------------ *
 * Top categories. Excel: "Top extra expense category(ies)".
 * One series, so one hue — the label carries identity.
 * ------------------------------------------------------------------ */
function CategoryChart({ rows }: { rows: CategorySpend[] }) {
  const byType = new Map<string, number>()
  for (const r of rows) {
    byType.set(r.type_name, (byType.get(r.type_name) ?? 0) + Number(r.spent ?? 0))
  }
  const ranked = [...byType.entries()]
    .filter(([, v]) => v > 0)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 12)

  if (ranked.length === 0) return null
  const max = ranked[0][1]
  const total = ranked.reduce((t, [, v]) => t + v, 0)

  return (
    <Card title="Where it went"
      note={`Top categories across these ${PERIODS} periods — ${fmt(total)} in all.`}>
      <ul className="mt-2">
        {ranked.map(([name, v]) => (
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
    </Card>
  )
}

/* ------------------------------------------------------------------ *
 * Income against spending by month. Excel: "YoY Income vs Bills/Expenses".
 * ------------------------------------------------------------------ */
function MonthlyChart({ rows }: { rows: MonthRow[] }) {
  if (rows.length === 0) return null
  const max = maxAbs(rows.flatMap((r) => [Number(r.income), Number(r.spending)]))

  return (
    <Card title="Income against spending"
      note="By month. The gap between the two bars is what was left.">
      <ul className="mt-2">
        {rows.map((r) => {
          const saved = Number(r.saved ?? 0)
          return (
            <li key={r.month} className="px-3 py-2">
              <div className="flex items-baseline justify-between gap-2">
                <span className="text-[13px]">{monthLabel(r.month)}</span>
                <span className="num text-xs" style={{ color: saved < 0 ? BAD : GOOD }}>
                  {saved < 0 ? '−' : '+'}{fmtShort(Math.abs(saved))}
                </span>
              </div>
              <div className="mt-1.5 space-y-[3px]">
                <div className="h-2" style={{ backgroundColor: SERIES[0], width: widthPct(Number(r.income), max) }}
                  title={`Income ${fmt(r.income)}`} />
                <div className="h-2" style={{ backgroundColor: SERIES[1], width: widthPct(Number(r.spending), max) }}
                  title={`Spending ${fmt(r.spending)}`} />
              </div>
            </li>
          )
        })}
      </ul>
      <Legend items={[
        { color: SERIES[0], label: 'Income' },
        { color: SERIES[1], label: 'Spending' },
      ]} />
    </Card>
  )
}

/* ------------------------------------------------------------------ */

export function Money() {
  const [periods, setPeriods] = useState<PeriodSummary[]>([])
  const [cats, setCats] = useState<CategorySpend[]>([])
  const [months, setMonths] = useState<MonthRow[]>([])
  const [err, setErr] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    void (async () => {
      const { data: p, error: pe } = await supabase
        .from('v_period_summary').select('*')
        .order('period_start', { ascending: false }).limit(PERIODS)
      if (pe) setErr(pe.message)
      const ps = ((p ?? []) as PeriodSummary[]).reverse()
      setPeriods(ps)

      if (ps.length > 0) {
        const { data: c } = await supabase
          .from('v_category_spend').select('budget_period_id,type_name,budgeted,spent')
          .in('budget_period_id', ps.map((r) => r.budget_period_id))
        setCats((c ?? []) as CategorySpend[])
      }

      const { data: m } = await supabase
        .from('v_income_vs_spending').select('*')
        .order('month', { ascending: false }).limit(PERIODS)
      setMonths(((m ?? []) as MonthRow[]).reverse())
      setLoading(false)
    })()
  }, [])

  const latest = periods[periods.length - 1]

  return (
    <>
      <div className="pt-5 pb-3">
        <h2 className="text-lg font-medium">MoneyView</h2>
        <p className="text-xs text-ink3 mt-0.5">
          {latest
            ? `Last ${periods.length} pay periods, through ${shortDate(latest.period_start)}.`
            : 'No pay periods yet.'}
        </p>
      </div>

      <Err msg={err} />
      {loading && <Empty>Loading…</Empty>}
      {!loading && periods.length === 0 && <Empty>Nothing to summarise yet.</Empty>}

      {latest && (
        <div className="grid gap-3 grid-cols-2 lg:grid-cols-4 pb-5">
          <Stat label="Paycheck" value={fmt(latest.wage_income)} />
          <Stat label="Everything due" value={fmt(latest.total_due)} />
          <Stat label="Left over"
            value={fmt(latest.balance_on_wages)}
            tone={Number(latest.balance_on_wages) < 0 ? 'bad' : 'good'} />
          <Stat label="Projected balance"
            value={fmt(latest.projected_balance)}
            tone={Number(latest.projected_balance) < 0 ? 'bad' : undefined} />
        </div>
      )}

      {periods.length > 0 && (
        <div className="grid gap-4 items-start lg:grid-cols-2">
          <CoverageChart rows={periods} />
          <FundingChart rows={periods} />
          <CategoryChart rows={cats} />
          <MonthlyChart rows={months} />
        </div>
      )}
    </>
  )
}
