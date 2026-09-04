import { useEffect, useMemo, useState } from 'react'
import { usePeriodDetail, usePeriods } from '../hooks/usePeriod'
import { LineRow } from '../components/LineRow'
import { Empty, Err } from '../components/Chrome'
import { AddFunds } from '../components/AddFunds'
import { supabase } from '../lib/supabase'
import { fmt, fmtDate, KIND_LABEL } from '../lib/format'
import type { AccountKind, BudgetLine } from '../lib/types'

const ORDER: AccountKind[] = ['bill', 'expense', 'debt', 'saving']

interface ExpenseName { name: string; last_used: string | null; times: number }

function AdHocLine({
  periodId, onDone, onError,
}: { periodId: number; onDone: () => void; onError: (m: string | null) => void }) {
  const [name, setName] = useState('')
  const [amount, setAmount] = useState('')
  const [kind, setKind] = useState('expense')
  const [busy, setBusy] = useState(false)
  const [known, setKnown] = useState<ExpenseName[]>([])

  // Everything ever spent on, from the catalogue and from past one-offs.
  useEffect(() => {
    void supabase.from('v_expense_names')
      .select('name,last_used,times')
      .order('times', { ascending: false })
      .then(({ data }) => setKnown((data ?? []) as ExpenseName[]))
  }, [])

  // Most used first, then most recent, so the obvious answer is at the top.
  const suggestions = useMemo(() => {
    const q = name.trim().toLowerCase()
    return known
      .filter((k) => !q || k.name.toLowerCase().includes(q))
      .sort((a, b) => (b.times - a.times)
        || (b.last_used ?? '').localeCompare(a.last_used ?? ''))
      .slice(0, 8)
  }, [known, name])

  async function save() {
    setBusy(true); onError(null)
    // No catalog entry — this is a one-time thing that only exists in this
    // period, like a car repair.
    const { error } = await supabase.rpc('add_adhoc_line', {
      p_period_id: periodId,
      p_name: name,
      p_amount: Number(amount || 0),
      p_category_id: null,
      p_kind: kind,
      p_due_date: null,
    })
    setBusy(false)
    if (error) onError(error.message)
    else onDone()
  }

  return (
    <div className="border border-rule p-3 space-y-3 mt-2">
      <p className="text-xs text-ink3">
        Adds it to this period only. For something that recurs, add it on the Bills tab instead.
      </p>
      <div className="grid grid-cols-2 gap-2">
        <label className="block">
          <span className="eyebrow block mb-1">What for</span>
          <input className="field" value={name} onChange={(e) => setName(e.target.value)}
            placeholder="Car repair" autoComplete="off" />
          {suggestions.length > 0 && (
            <div className="flex flex-wrap gap-1 mt-1.5">
              {suggestions.map((k) => (
                <button key={k.name} type="button"
                  className="border border-rule bg-surface px-1.5 py-0.5 text-[11px]
                             hover:bg-bar max-w-full truncate"
                  title={k.last_used ? `Last used ${fmtDate(k.last_used)}` : 'From the Bills tab'}
                  onClick={() => setName(k.name)}>
                  {k.name}
                </button>
              ))}
            </div>
          )}
        </label>
        <label className="block">
          <span className="eyebrow block mb-1">Amount</span>
          <input className="field" inputMode="decimal" value={amount}
            onChange={(e) => setAmount(e.target.value)} />
        </label>
      </div>
      <label className="block">
        <span className="eyebrow block mb-1">Counts as</span>
        <select className="field" value={kind} onChange={(e) => setKind(e.target.value)}>
          <option value="expense">Expense</option>
          <option value="bill">Bill</option>
          <option value="debt">Debt payment</option>
          <option value="saving">Savings</option>
        </select>
      </label>
      <button className="btn-go" disabled={busy || !name.trim() || !amount} onClick={save}>
        {busy ? 'Adding…' : 'Add to this period'}
      </button>
    </div>
  )
}

function Line({ label, value, strong }: { label: string; value?: number; strong?: boolean }) {
  const n = Number(value ?? 0)
  return (
    <div className="flex justify-between">
      <dt className={strong ? 'font-medium' : 'text-ink3'}>{label}</dt>
      <dd className={`num ${strong ? (n < 0 ? 'text-rust font-medium' : 'text-moss font-medium') : ''}`}>
        {fmt(n)}
      </dd>
    </div>
  )
}

export function Period({ isOwner }: { isOwner: boolean }) {
  const { current, hasPrev, hasNext, prev, next } = usePeriods()
  const { summary, lines, funding, loading, reload } = usePeriodDetail(current?.id ?? null)
  const [err, setErr] = useState<string | null>(null)
  const [addingLine, setAddingLine] = useState(false)
  const [refreshing, setRefreshing] = useState(false)
  const [upkeep, setUpkeep] = useState<string | null>(null)

  // The same thing the nightly job runs: extend the calendar, then
  // materialise and reprice every open period. Idempotent, so pressing it
  // when there is nothing to do simply reports nothing to do.
  async function refreshBudget() {
    setRefreshing(true); setErr(null); setUpkeep(null)
    const { data, error } = await supabase.rpc('run_budget_upkeep')
    setRefreshing(false)
    if (error) { setErr(error.message); return }
    const rows = (data ?? []) as {
      periods_added: number; lines_created: number; lines_repriced: number
    }[]
    const t = rows.reduce((a, r) => ({
      p: a.p + Number(r.periods_added ?? 0),
      c: a.c + Number(r.lines_created ?? 0),
      r: a.r + Number(r.lines_repriced ?? 0),
    }), { p: 0, c: 0, r: 0 })
    setUpkeep(
      t.p === 0 && t.c === 0 && t.r === 0
        ? 'Already up to date.'
        : `${t.p} period${t.p === 1 ? '' : 's'} added · `
          + `${t.c} line${t.c === 1 ? '' : 's'} created · `
          + `${t.r} repriced.`)
    reload()
  }

  const grouped = useMemo(() => {
    const g = new Map<AccountKind, BudgetLine[]>()
    for (const l of lines) {
      const arr = g.get(l.kind) ?? []
      arr.push(l)
      g.set(l.kind, arr)
    }
    return g
  }, [lines])

  if (!current) return <Empty>No pay periods yet. Generate them from the Bills tab.</Empty>

  // Amounts belong to the period they were set in. Once you have navigated
  // off the period you are actually living in, the figures are history --
  // editing them there rewrites what a past fortnight cost, and a future
  // period gets its amounts from the account when it materialises anyway.
  const today = new Date().toISOString().slice(0, 10)
  const inThisPeriod = current.period_start <= today && today <= current.period_end
  const editable = inThisPeriod && !current.is_closed

  const left = Number(summary?.remaining_due ?? 0)

  return (
    <>
      <div className="flex items-center justify-between pt-5 pb-1">
        <button className="btn px-2 py-1" onClick={prev} disabled={!hasPrev} aria-label="Previous period">←</button>
        <span className="eyebrow">
          {fmtDate(current.period_start)} – {fmtDate(current.period_end)}
          {current.is_closed && ' · closed'}
        </span>
        <button className="btn px-2 py-1" onClick={next} disabled={!hasNext} aria-label="Next period">→</button>
      </div>

      {/* The one big number: what is still owed out of this paycheck. */}
      <div className="py-5 border-b border-rule">
        <p className="eyebrow">Still to pay</p>
        <p className={`num text-[42px] leading-none mt-1 ${left > 0 ? '' : 'text-moss'}`}>
          {fmt(left)}
        </p>
        <p className="text-sm text-ink3 mt-2">
          {summary?.paid_count ?? 0} of {summary?.line_count ?? 0} paid ·{' '}
          {fmt(summary?.total_due)} budgeted
        </p>

        <dl className="mt-3 space-y-1 text-sm">
          <Line label="From pay" value={summary?.wage_income} />
          {Number(summary?.bonus_income ?? 0) > 0 && <Line label="Bonus" value={summary?.bonus_income} />}
          {Number(summary?.from_savings ?? 0) > 0 && <Line label="From savings" value={summary?.from_savings} />}
          {Number(summary?.from_credit ?? 0) > 0 && <Line label="From credit line" value={summary?.from_credit} />}
          <Line label="Projected left over" value={summary?.projected_balance} strong />
        </dl>

        {Number(summary?.balance_on_wages ?? 0) < 0 && (
          <p className="mt-2 text-xs text-amber">
            Pay alone is {fmt(Math.abs(Number(summary?.balance_on_wages)))} short this period.
          </p>
        )}
      </div>

      <Err msg={err} />

      {isOwner && current && (
        <>
          <div className="pt-4">
            <button className={`btn ${addingLine ? 'bg-ink text-paper border-ink' : ''}`}
              disabled={!editable}
              title={editable ? undefined : 'Only the current pay period can be changed'}
              onClick={() => setAddingLine((a) => !a)}>
              {addingLine ? 'Cancel' : '+ One-off expense'}
            </button>

            <button className="btn ml-2" disabled={refreshing}
              title="Extend the pay calendar and rebuild any missing lines. Runs nightly anyway."
              onClick={() => void refreshBudget()}>
              {refreshing ? 'Refreshing…' : 'Refresh budget'}
            </button>

            {upkeep && (
              <span className="eyebrow ml-3 normal-case tracking-normal">{upkeep}</span>
            )}
          </div>
          {addingLine && (
            <AdHocLine periodId={current.id} onError={setErr}
              onDone={() => { setAddingLine(false); reload() }} />
          )}
          <AddFunds periodId={current.id} rows={funding} onChange={reload} onError={setErr} />
        </>
      )}

      {loading ? (
        <Empty>Loading…</Empty>
      ) : lines.length === 0 ? (
        <Empty>Nothing scheduled in this period yet.</Empty>
      ) : (
        ORDER.filter((k) => grouped.has(k)).map((kind) => (
          <section key={kind} className="mt-6">
            <div className="flex items-baseline justify-between mb-1">
              <h2 className="eyebrow">{KIND_LABEL[kind]}</h2>
              <span className="num text-xs text-ink3">
                {fmt(grouped.get(kind)!.reduce((s, l) => s + Number(l.amount_due), 0))}
              </span>
            </div>
            <ul className="border border-rule">
              {grouped.get(kind)!.map((l) => (
                <LineRow key={l.id} line={l} isOwner={isOwner} editable={editable}
                  onChange={reload} onError={setErr} />
              ))}
            </ul>
          </section>
        ))
      )}
    </>
  )
}
