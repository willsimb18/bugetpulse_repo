import { useMemo, useState } from 'react'
import { usePeriodDetail, usePeriods } from '../hooks/usePeriod'
import { LineRow } from '../components/LineRow'
import { Empty, Err } from '../components/Chrome'
import { AddFunds } from '../components/AddFunds'
import { supabase } from '../lib/supabase'
import { fmt, fmtDate, KIND_LABEL } from '../lib/format'
import type { AccountKind, BudgetLine } from '../lib/types'

const ORDER: AccountKind[] = ['bill', 'expense', 'debt', 'saving']

function AdHocLine({
  periodId, onDone, onError,
}: { periodId: number; onDone: () => void; onError: (m: string | null) => void }) {
  const [name, setName] = useState('')
  const [amount, setAmount] = useState('')
  const [kind, setKind] = useState('expense')
  const [busy, setBusy] = useState(false)

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
            placeholder="Car repair" />
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
              onClick={() => setAddingLine((a) => !a)}>
              {addingLine ? 'Cancel' : '+ One-off expense'}
            </button>
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
                <LineRow key={l.id} line={l} isOwner={isOwner} onChange={reload} onError={setErr} />
              ))}
            </ul>
          </section>
        ))
      )}
    </>
  )
}
