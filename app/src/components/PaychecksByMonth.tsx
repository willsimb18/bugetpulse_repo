import { useMemo, useState } from 'react'
import { fmt, fmtShort } from '../lib/format'
import { SERIES, maxAbs, monthLabel, widthPct } from '../lib/chart'
import type { IncomeRow } from '../lib/types'

/*
 * "Paychecks by month", from the MoneyView tab.
 *
 * Wages only — is_wage() in the database counts regular, overtime, PTO,
 * holiday and commission, and the same list is applied here so the figure
 * matches what v_period_summary calls wage_income. A savings draw or a
 * credit draw is money moved in, not a paycheck, and would otherwise
 * inflate a month that was actually short.
 */
const WAGE_KINDS = new Set(['regular', 'overtime', 'pto', 'holiday', 'commission'])

const ALL = 'all'

export function PaychecksByMonth({ rows }: { rows: IncomeRow[] }) {
  const [year, setYear] = useState<string>(ALL)

  const years = useMemo(
    () => [...new Set(rows.map((r) => r.received_on?.slice(0, 4)).filter(Boolean) as string[])]
      .sort().reverse(),
    [rows])

  // Default to the most recent year that has any wages in it.
  const active = year === ALL && years.length > 0 ? years[0] : year

  const byMonth = useMemo(() => {
    const acc = new Map<string, { net: number; gross: number; n: number }>()
    for (const r of rows) {
      if (!WAGE_KINDS.has(r.kind)) continue
      if (!r.received_on) continue
      if (active !== ALL && r.received_on.slice(0, 4) !== active) continue
      const key = `${r.received_on.slice(0, 7)}-01`
      const cur = acc.get(key) ?? { net: 0, gross: 0, n: 0 }
      cur.net += Number(r.net ?? 0)
      cur.gross += Number(r.gross ?? 0)
      cur.n += 1
      acc.set(key, cur)
    }
    return [...acc.entries()].sort((a, b) => a[0].localeCompare(b[0]))
  }, [rows, active])

  const max = maxAbs(byMonth.map(([, v]) => v.net))
  const total = byMonth.reduce((t, [, v]) => t + v.net, 0)

  return (
    <section className="border border-rule min-w-0">
      <header className="px-3 pt-3 flex items-start justify-between gap-3">
        <div className="min-w-0">
          <h3 className="text-[15px]">Paychecks by month</h3>
          <p className="text-xs text-ink3 mt-0.5">
            Take-home pay. {byMonth.length > 0 && `${fmt(total)} across ${byMonth.length} months.`}
          </p>
        </div>
        <label className="flex items-center gap-1.5 shrink-0">
          <span className="eyebrow">Year</span>
          <select className="border border-rule bg-white px-2 py-1 text-xs"
            value={active} onChange={(e) => setYear(e.target.value)}>
            <option value={ALL}>All</option>
            {years.map((y) => <option key={y} value={y}>{y}</option>)}
          </select>
        </label>
      </header>

      {byMonth.length === 0 ? (
        <p className="text-xs text-ink3 px-3 py-4">No paychecks recorded in this year.</p>
      ) : (
        <ul className="mt-2">
          {byMonth.map(([month, v]) => (
            <li key={month} className="px-3 py-2">
              <div className="flex items-baseline justify-between gap-2">
                <span className="text-[13px]">{monthLabel(month)}</span>
                <span className="num text-xs text-ink3">{fmtShort(v.net)}</span>
              </div>
              <div className="mt-1.5 h-2.5 bg-rule/30">
                <div className="h-full"
                  title={`${fmt(v.net)} net of ${fmt(v.gross)} gross`}
                  style={{ backgroundColor: SERIES[0], width: widthPct(v.net, max) }} />
              </div>
              <p className="text-[11px] text-ink3 mt-1">
                {v.n} paycheck{v.n === 1 ? '' : 's'} · <span className="num">{fmtShort(v.gross)}</span> gross
              </p>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}
