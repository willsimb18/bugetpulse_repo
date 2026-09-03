import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { Empty, Err } from '../components/Chrome'
import { fmt, fmtDate, fmtShort } from '../lib/format'
import { monthLabel } from '../lib/chart'
import type { IncomeRow, WageRow } from '../lib/types'
import { PaychecksByMonth } from '../components/PaychecksByMonth'

const THIS_YEAR = String(new Date().getFullYear())

/* Only the two kinds that are actually a paycheck. */
const PAYCHECK_KINDS = new Set(['regular', 'bonus'])

export function Income({ isOwner }: { isOwner: boolean }) {
  const [wages, setWages] = useState<WageRow[]>([])
  const [earners, setEarners] = useState<{ id: number; display_name: string }[]>([])
  const [err, setErr] = useState<string | null>(null)
  const [showRaise, setShowRaise] = useState(false)
  const [showCheck, setShowCheck] = useState(false)
  const [showRates, setShowRates] = useState(false)
  const [periods, setPeriods] = useState<{ id: number; label: string | null; pay_date: string }[]>([])
  const [allIncome, setAllIncome] = useState<IncomeRow[]>([])

  const load = useCallback(async () => {
    const [w, e] = await Promise.all([
      supabase.from('v_wage_history').select('*').order('effective_from', { ascending: false }),
      supabase.from('earner').select('id, display_name').eq('is_active', true).order('display_name'),
    ])
    setWages((w.data ?? []) as WageRow[])
    setEarners((e.data ?? []) as { id: number; display_name: string }[])
    const { data: p } = await supabase
      .from('budget_period').select('id, label, pay_date')
      .eq('is_closed', false).order('pay_date', { ascending: false }).limit(12)
    setPeriods((p ?? []) as typeof periods)

    // The list shows the last 40; the chart needs every month there is.
    const { data: all } = await supabase
      .from('v_income_history').select('*').order('received_on')
    setAllIncome((all ?? []) as IncomeRow[])
  }, [])

  useEffect(() => { void load() }, [load])

  return (
    <>
      <div className="flex items-baseline justify-between pt-5 pb-3">
        <h2 className="text-lg font-medium">Income</h2>
        {isOwner && (
          <div className="flex gap-2">
            <button className={`btn ${showCheck ? 'bg-ink text-paper border-ink' : ''}`}
              onClick={() => { setShowCheck((s) => !s); setShowRaise(false) }}>
              + Paycheck
            </button>
            <button className={`btn ${showRaise ? 'bg-ink text-paper border-ink' : ''}`}
              onClick={() => { setShowRaise((s) => !s); setShowCheck(false) }}>
              Record a raise
            </button>
          </div>
        )}
      </div>

      <Err msg={err} />

      {showCheck && (
        <PaycheckForm
          earners={earners}
          periods={periods}
          onDone={() => { setShowCheck(false); void load() }}
          onError={setErr}
        />
      )}

      {showRaise && (
        <RaiseForm
          earners={earners}
          onDone={() => { setShowRaise(false); void load() }}
          onError={setErr}
        />
      )}

      <div className="grid gap-x-6 gap-y-6 items-start lg:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)]">
      <div className="min-w-0">
      <section className="mt-4">
        <div className="flex items-baseline justify-between mb-1">
          <h3 className="eyebrow">Pay rate history</h3>
          <button className="eyebrow hover:text-ink"
            onClick={() => setShowRates((v) => !v)}
            aria-pressed={showRates}>
            {showRates ? 'Hide' : 'Show'} rates
          </button>
        </div>
        {wages.length === 0 ? (
          <Empty>No rates on file. Record a raise to set a starting rate.</Empty>
        ) : (
          <ul className="border border-rule">
            {wages.map((w, i) => (
              <li key={i} className="bar-row flex items-center gap-3 px-3 py-2.5">
                <span className="flex-1 min-w-0">
                  <span className="block text-[15px]">{w.earner}</span>
                  <span className="eyebrow">
                    from {fmtDate(w.effective_from)}
                    {w.note && ` · ${w.note}`}
                  </span>
                </span>
                <span className="text-right">
                  <span className="num block text-[15px]">
                    {showRates ? `${fmt(w.hourly_rate)}/hr` : '••••••'}
                  </span>
                  {w.pct_increase != null && (
                    <span className="num text-xs text-moss">+{Number(w.pct_increase).toFixed(2)}%</span>
                  )}
                </span>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section className="mt-6">
        <h3 className="eyebrow mb-1">Paychecks · {THIS_YEAR}</h3>
        <PaycheckMonths rows={allIncome} />
      </section>
      </div>

      <div className="min-w-0 lg:mt-4">
        <PaychecksByMonth rows={allIncome} />
      </div>
      </div>
    </>
  )
}

/*
 * Paychecks for the current year only, and only the kinds that are
 * actually a paycheck: regular and bonus. Grouped by month, then by who
 * was paid, each level carrying its own total.
 */
function PaycheckMonths({ rows }: { rows: IncomeRow[] }) {
  const mine = rows.filter(
    (r) => PAYCHECK_KINDS.has(r.kind) &&
           (r.received_on ?? '').slice(0, 4) === THIS_YEAR)

  if (mine.length === 0) {
    return <Empty>No paychecks recorded in {THIS_YEAR}.</Empty>
  }

  const months = new Map<string, IncomeRow[]>()
  for (const r of mine) {
    const key = `${(r.received_on ?? '').slice(0, 7)}-01`
    months.set(key, [...(months.get(key) ?? []), r])
  }
  const ordered = [...months.entries()].sort((a, b) => b[0].localeCompare(a[0]))
  const sum = (xs: IncomeRow[]) => xs.reduce((t, r) => t + Number(r.net ?? 0), 0)

  return (
    <div className="space-y-4">
      {ordered.map(([month, items]) => {
        const byEarner = new Map<string, IncomeRow[]>()
        for (const r of items) {
          const who = r.earner ?? 'Household'
          byEarner.set(who, [...(byEarner.get(who) ?? []), r])
        }
        return (
          <div key={month}>
            <div className="flex items-baseline justify-between pb-1">
              <h4 className="eyebrow">{monthLabel(month)}</h4>
              <span className="num text-xs text-ink3">{fmtShort(sum(items))}</span>
            </div>
            <ul className="border border-rule">
              {[...byEarner.entries()].sort().map(([who, checks]) => (
                <li key={who} className="bar-row px-3 py-2.5">
                  <div className="flex items-baseline justify-between gap-3">
                    <span className="text-[15px] truncate min-w-0">{who}</span>
                    <span className="num text-[15px] shrink-0">{fmt(sum(checks))}</span>
                  </div>
                  <ul className="mt-1">
                    {checks
                      .sort((a, b) => (a.received_on ?? '').localeCompare(b.received_on ?? ''))
                      .map((c) => (
                        <li key={c.id}
                          className="flex items-baseline justify-between gap-2 py-0.5 text-[12px]">
                          <span className="min-w-0 truncate text-ink3">
                            <span className="num">{fmtDate(c.received_on)}</span>
                            {c.kind !== 'regular' && ` · ${c.kind}`}
                            {c.hours ? ` · ${c.hours} hrs` : ''}
                            {' · gross '}<span className="num">{fmtShort(c.gross)}</span>
                          </span>
                          <span className="num shrink-0">{fmt(c.net)}</span>
                        </li>
                    ))}
                  </ul>
                </li>
              ))}
            </ul>
          </div>
        )
      })}
    </div>
  )
}

function PaycheckForm({
  earners, periods, onDone, onError,
}: {
  earners: { id: number; display_name: string }[]
  periods: { id: number; label: string | null; pay_date: string }[]
  onDone: () => void
  onError: (m: string | null) => void
}) {
  const [earnerId, setEarnerId] = useState<number | ''>(earners[0]?.id ?? '')
  const [periodId, setPeriodId] = useState<number | ''>(periods[0]?.id ?? '')
  const [hours, setHours] = useState('')
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (earnerId === '' && earners[0]) setEarnerId(earners[0].id)
    if (periodId === '' && periods[0]) setPeriodId(periods[0].id)
  }, [earners, periods, earnerId, periodId])

  async function save() {
    setBusy(true); onError(null)
    // Rate, taxes and deductions come from the wage_rate in effect on the
    // pay date, so there's nothing to retype every fortnight.
    const { error } = await supabase.rpc('record_paycheck', {
      p_earner_id: Number(earnerId),
      p_period_id: Number(periodId),
      p_check_date: null,
      p_hours: hours ? Number(hours) : null,
      p_kind: 'regular',
    })
    setBusy(false)
    if (error) onError(error.message)
    else onDone()
  }

  return (
    <div className="border border-rule p-3 space-y-3">
      <p className="text-xs text-ink3">
        Pay rate and deductions are filled in from the rate in effect on the pay date.
        Leave hours blank to use the standard hours on that rate.
      </p>
      <div className="grid grid-cols-2 gap-2">
        <label className="block">
          <span className="eyebrow block mb-1">Who</span>
          <select className="field" value={earnerId}
            onChange={(e) => setEarnerId(Number(e.target.value))}>
            {earners.map((e) => <option key={e.id} value={e.id}>{e.display_name}</option>)}
          </select>
        </label>
        <label className="block">
          <span className="eyebrow block mb-1">Pay period</span>
          <select className="field" value={periodId}
            onChange={(e) => setPeriodId(Number(e.target.value))}>
            {periods.map((p) => (
              <option key={p.id} value={p.id}>{p.label ?? p.pay_date}</option>
            ))}
          </select>
        </label>
      </div>
      <label className="block">
        <span className="eyebrow block mb-1">Hours (optional)</span>
        <input className="field" inputMode="decimal" value={hours}
          onChange={(e) => setHours(e.target.value)} placeholder="80" />
      </label>
      <button className="btn-go" disabled={busy || !earnerId || !periodId} onClick={save}>
        {busy ? 'Saving…' : 'Record paycheck'}
      </button>
    </div>
  )
}

function RaiseForm({
  earners, onDone, onError,
}: {
  earners: { id: number; display_name: string }[]
  onDone: () => void
  onError: (m: string | null) => void
}) {
  const [earnerId, setEarnerId] = useState<number | ''>(earners[0]?.id ?? '')
  const [from, setFrom] = useState(new Date().toISOString().slice(0, 10))
  const [rate, setRate] = useState('')
  const [hours, setHours] = useState('80')
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)

  async function save() {
    setBusy(true); onError(null)
    const { error } = await supabase.rpc('apply_raise', {
      p_earner_id: Number(earnerId),
      p_effective_from: from,
      p_hourly_rate: rate ? Number(rate) : null,
      p_standard_hours: hours ? Number(hours) : null,
      p_note: note || null,
    })
    setBusy(false)
    if (error) onError(error.message)
    else onDone()
  }

  return (
    <div className="border border-rule p-3 space-y-3">
      <p className="text-xs text-ink3">
        Past paychecks keep the rate they were paid at. This applies from the date you choose.
      </p>
      <label className="block">
        <span className="eyebrow block mb-1">Who</span>
        <select className="field" value={earnerId}
          onChange={(e) => setEarnerId(Number(e.target.value))}>
          {earners.map((e) => <option key={e.id} value={e.id}>{e.display_name}</option>)}
        </select>
      </label>
      <div className="grid grid-cols-2 gap-2">
        <label className="block">
          <span className="eyebrow block mb-1">Effective from</span>
          <input className="field" type="date" value={from} onChange={(e) => setFrom(e.target.value)} />
        </label>
        <label className="block">
          <span className="eyebrow block mb-1">Hourly rate</span>
          <input className="field" inputMode="decimal" value={rate}
            onChange={(e) => setRate(e.target.value)} />
        </label>
      </div>
      <div className="grid grid-cols-2 gap-2">
        <label className="block">
          <span className="eyebrow block mb-1">Hours per period</span>
          <input className="field" inputMode="decimal" value={hours}
            onChange={(e) => setHours(e.target.value)} />
        </label>
        <label className="block">
          <span className="eyebrow block mb-1">Note</span>
          <input className="field" value={note} onChange={(e) => setNote(e.target.value)} />
        </label>
      </div>
      <button className="btn-go" disabled={busy || !earnerId || !rate} onClick={save}>
        {busy ? 'Saving…' : 'Save raise'}
      </button>
    </div>
  )
}
