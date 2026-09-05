import { useEffect, useMemo, useState } from 'react'
import { usePeriodDetail, usePeriods } from '../hooks/usePeriod'
import { LineRow } from '../components/LineRow'
import { PeriodDonut } from '../components/PeriodDonut'
import { Empty, Err } from '../components/Chrome'
import { AddFunds } from '../components/AddFunds'
import { supabase } from '../lib/supabase'
import { fmt, fmtDate, KIND_LABEL, URGENCY_LEGEND, urgencyLabel } from '../lib/format'
import { downloadCsv, toCsv } from '../lib/csv'
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
  const [groupBy, setGroupBy] = useState<'kind' | 'category'>('kind')

  /*
   * Exports the period on screen, in the order it is on screen, so the
   * file matches what was being looked at when the button was pressed.
   *
   * Both sides of the ledger go in. Budget lines carry row_type
   * "budget_line"; the money that funded them carries "income" and names
   * its source in income_type, so summing amount_paid by row_type gives
   * what came in against what went out. The period's income totals repeat
   * on every row as well — redundant, but it means one row is enough to
   * reconstruct the period without a lookup.
   *
   * The paycheck is added by hand: v_period_funding is defined as
   * `where not is_wage(kind)`, so it holds the savings and credit draws
   * and deliberately not the wages.
   */
  function exportCsv() {
    if (!current) return

    const inc = {
      total: Number(summary?.net_income ?? 0).toFixed(2),
      pay: Number(summary?.wage_income ?? 0).toFixed(2),
      savings: Number(summary?.from_savings ?? 0).toFixed(2),
      credit: Number(summary?.from_credit ?? 0).toFixed(2),
      bonus: Number(summary?.bonus_income ?? 0).toFixed(2),
      other: Number(summary?.other_funding ?? 0).toFixed(2),
    }
    const period = [current.period_start, current.label ?? '']
    const totals = [inc.total, inc.pay, inc.savings, inc.credit, inc.bonus, inc.other]

    const lineRows = groups.flatMap((g) =>
      g.items.map((l) => [
        'budget_line', ...period,
        groupBy === 'kind' ? KIND_LABEL[l.kind] ?? l.kind : g.label,
        l.name, l.type_name ?? '', l.sub_type_name ?? '', l.kind,
        '',                                   // income_type
        l.due_date, l.status, urgencyLabel(l.due_date, l.status),
        Number(l.amount_due ?? 0).toFixed(2),
        Number(l.amount_paid ?? 0).toFixed(2),
        l.paid_on ?? '', l.settled_on ?? '',
        l.last_paid_amount == null ? '' : Number(l.last_paid_amount).toFixed(2),
        l.last_paid_on ?? '',
        ...totals,
      ]))

    const wage = Number(summary?.wage_income ?? 0)
    const incomeRows = [
      ...(wage > 0 ? [[
        'income', ...period, 'Income', 'Paycheck', '', '', '', 'regular',
        current.pay_date, 'received', '', '', wage.toFixed(2),
        current.pay_date, current.pay_date, '', '', ...totals,
      ]] : []),
      ...funding.map((f) => [
        'income', ...period, 'Income',
        f.source_account ?? f.kind.replace(/_/g, ' '),
        '', '', '', f.kind,
        f.received_on, 'received', '', '',
        Number(f.amount ?? 0).toFixed(2),
        f.received_on, f.received_on, '', '', ...totals,
      ]),
    ]

    const csv = toCsv([
      'row_type', 'period_start', 'period_label', 'group', 'name',
      'category', 'sub_category', 'kind', 'income_type',
      'due_date', 'status', 'due_in',
      'amount_due', 'amount_paid', 'paid_on', 'settled_on',
      'last_paid_amount', 'last_paid_on',
      'period_income_total', 'period_income_from_pay',
      'period_income_from_savings', 'period_income_from_credit',
      'period_income_bonus', 'period_income_other',
    ], [...lineRows, ...incomeRows])

    downloadCsv(`budgetpulse-${current.period_start}.csv`, csv)
  }
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

  const groups = useMemo(() => {
    const g = new Map<string, BudgetLine[]>()
    for (const l of lines) {
      const key = groupBy === 'kind' ? l.kind : (l.type_name ?? 'Uncategorised')
      g.set(key, [...(g.get(key) ?? []), l])
    }
    const total = (ls: BudgetLine[]) =>
      ls.reduce((t, l) => t + Number(l.amount_due ?? 0), 0)

    if (groupBy === 'kind') {
      return ORDER.filter((k) => g.has(k)).map((k) => ({
        key: k, label: KIND_LABEL[k], items: g.get(k)!, total: total(g.get(k)!),
      }))
    }
    // Biggest first — the order you would want to read a spend breakdown in.
    return [...g.entries()]
      .map(([key, items]) => ({ key, label: key, items, total: total(items) }))
      .sort((a, b) => b.total - a.total)
  }, [lines, groupBy])

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

            <button className="btn ml-2" disabled={lines.length === 0}
              title="Download this period's budget as a CSV"
              onClick={exportCsv}>
              Export CSV
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
          <AddFunds periodId={current.id} rows={funding} editable={editable}
            onChange={reload} onError={setErr} />
        </>
      )}

      {loading ? (
        <Empty>Loading…</Empty>
      ) : lines.length === 0 ? (
        <Empty>Nothing scheduled in this period yet.</Empty>
      ) : (
        <>
        {/*
          The filter and the legend belong to the page, not to the left
          column. Kept inside it they pushed the first list down while the
          donut beside it started at the top, so the two cards never lined
          up. Above the grid, both columns begin on the same line.
        */}
        <div className="flex flex-wrap items-center gap-x-6 gap-y-2 pt-4 pb-2">
          <div className="flex items-center gap-1.5">
            <span className="eyebrow">List by</span>
            {([['kind', 'Accounts'], ['category', 'Category']] as const).map(([v, label]) => (
              <button key={v}
                className={`btn py-0.5 text-[11px] ${
                  groupBy === v ? 'bg-ink text-paper border-ink' : ''}`}
                onClick={() => setGroupBy(v)}>
                {label}
              </button>
            ))}
          </div>

          <p className="flex flex-wrap items-center gap-x-4 gap-y-1 text-[11px] text-ink3">
            {URGENCY_LEGEND.map((l) => (
              <span key={l.key} className="flex items-center gap-1.5">
                <span aria-hidden
                  className={`w-1.5 h-1.5 rounded-full shrink-0 ${l.dot}`} />
                {l.label}
              </span>
            ))}
          </p>
        </div>

        <div className="grid gap-x-6 gap-y-6 items-start
                        xl:grid-cols-[minmax(0,1fr)_minmax(0,30rem)]">
          <div className="min-w-0">
            {groups.map((g) => (
              <section key={g.key} className="mb-5">
                <div className="flex items-baseline justify-between mb-1">
                  <h2 className="eyebrow">{g.label}</h2>
                  <span className="num text-xs text-ink3">{fmt(g.total)}</span>
                </div>
                {/*
                  Same widths, gap and padding as LineRow's own row, and
                  the same responsive classes — a column that hides at a
                  breakpoint takes its heading with it. The dot and the
                  tick get spacers rather than labels: neither is a column
                  anyone reads down.
                */}
                <div className="flex items-center gap-3 px-3 pb-1 text-[10px]
                                uppercase tracking-[0.14em] text-ink3 font-medium">
                  <span aria-hidden className="w-1.5 shrink-0" />
                  <span className="flex-1 min-w-0">Name</span>
                  <span className="hidden md:block w-24 shrink-0">Status</span>
                  <span className="hidden sm:block w-36 shrink-0">Category</span>
                  <span className="w-28 shrink-0 text-right">Amount</span>
                  <span aria-hidden className="w-7 shrink-0" />
                </div>

                <ul className="border border-rule">
                  {g.items.map((l) => (
                    <LineRow key={l.id} line={l} isOwner={isOwner} editable={editable}
                      onChange={reload} onError={setErr} />
                  ))}
                </ul>
              </section>
            ))}
          </div>

          <div className="min-w-0">
            <PeriodDonut lines={lines} summary={summary} groupBy={groupBy} />
          </div>
        </div>
        </>
      )}
    </>
  )
}
