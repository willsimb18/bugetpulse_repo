import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { Empty, Err } from '../components/Chrome'
import { DEBT_TYPE_LABEL, DEBT_TYPE_ORDER, fmt, fmtDate } from '../lib/format'
import type { DebtStatus } from '../lib/types'
import { NewAccount } from '../components/NewAccount'
import { DebtBalanceForm } from '../components/DebtBalanceForm'
import { DebtTermsForm } from '../components/DebtTermsForm'
import { BalanceShareChart, UtilizationChart } from '../components/DebtCharts'

type Strategy = 'avalanche' | 'snowball'

function Row({ k, v }: { k: string; v: string }) {
  return <><dt>{k}</dt><dd className="num text-right text-ink">{v}</dd></>
}

export function Debts({ isOwner }: { isOwner: boolean }) {
  const [rows, setRows] = useState<DebtStatus[]>([])
  const [strategy, setStrategy] = useState<Strategy>('avalanche')
  const [err, setErr] = useState<string | null>(null)
  const [openId, setOpenId] = useState<number | null>(null)
  const [adding, setAdding] = useState(false)
  const [subType, setSubType] = useState<string>('all')

  const load = useCallback(async () => {
    const { data, error } = await supabase.from('v_debt_status').select('*')
    if (error) setErr(error.message)
    setRows((data ?? []) as DebtStatus[])
  }, [])

  useEffect(() => { void load() }, [load])

  // Types actually present, in fixed order, plus anything unrecognised.
  const presentTypes = [
    ...DEBT_TYPE_ORDER.filter((t) => rows.some((r) => r.debt_type === t)),
    ...[...new Set(rows.map((r) => r.debt_type))]
      .filter((t) => !DEBT_TYPE_ORDER.includes(t)).sort(),
  ]

  const shown = subType === 'all' ? rows : rows.filter((r) => r.debt_type === subType)

  // Rank once across everything shown, so the numbers still read as a
  // payoff order after the rows are split into groups.
  const sorted = [...shown].sort((a, b) =>
    strategy === 'avalanche' ? a.avalanche_rank - b.avalanche_rank : a.snowball_rank - b.snowball_rank)

  const groups = presentTypes
    .filter((t) => subType === 'all' || t === subType)
    .map((type) => ({ type, items: sorted.filter((d) => d.debt_type === type) }))
    .filter((g) => g.items.length > 0)

  const rankOf = (id: number) => sorted.findIndex((d) => d.id === id) + 1

  const total = shown.reduce((s, r) => s + Number(r.current_balance ?? 0), 0)

  return (
    <>
      <div className="pt-5 pb-1 flex items-end justify-between gap-4">
        <div>
          <p className="eyebrow">
            Total owed{subType !== 'all' && ` · ${DEBT_TYPE_LABEL[subType] ?? subType}`}
          </p>
          <p className="num text-[34px] leading-none mt-1">{fmt(total)}</p>
        </div>

        <label className="flex items-center gap-1.5 shrink-0 pb-1">
          <span className="eyebrow">Sub type</span>
          <select
            className="border border-rule bg-white px-2 py-1 text-xs"
            value={subType}
            onChange={(e) => setSubType(e.target.value)}
          >
            <option value="all">All ({rows.length})</option>
            {presentTypes.map((t) => (
              <option key={t} value={t}>
                {DEBT_TYPE_LABEL[t] ?? t} ({rows.filter((r) => r.debt_type === t).length})
              </option>
            ))}
          </select>
        </label>
      </div>

      <Err msg={err} />

      {adding && (
        <NewAccount kind="debt" onError={setErr}
          onCancel={() => setAdding(false)}
          onDone={() => { setAdding(false); void load() }} />
      )}

      {/*
        Payoff order, then the two charts. The list carries far more per
        row -- rank, name, APR, gauge, balance, headroom -- so it gets 1.6
        shares against 1 each for the charts rather than an equal third.
        Stacks to a single column below lg, so the phone view is untouched.
      */}
      <div className="grid gap-x-6 gap-y-6 items-start
                      lg:grid-cols-[minmax(0,1.6fr)_minmax(0,1fr)_minmax(0,1fr)]">
        <div className="min-w-0">
          <div className="flex flex-wrap gap-2 py-4">
            {(['avalanche', 'snowball'] as Strategy[]).map((s) => (
              <button key={s} onClick={() => setStrategy(s)}
                className={`btn ${strategy === s ? 'bg-ink text-paper border-ink' : ''}`}>
                {s === 'avalanche' ? 'Highest rate first' : 'Smallest balance first'}
              </button>
            ))}
          </div>

          {isOwner && (
            <button className={`btn mb-3 ${adding ? 'bg-ink text-paper border-ink' : ''}`}
              onClick={() => setAdding((a) => !a)}>
              {adding ? 'Cancel' : '+ Add a debt'}
            </button>
          )}

          {sorted.length === 0 && !adding && (
            <Empty>
              {subType === 'all'
                ? 'No debts tracked yet.'
                : `No ${(DEBT_TYPE_LABEL[subType] ?? subType).toLowerCase()} tracked.`}
            </Empty>
          )}

          {groups.map((g) => (
          <section key={g.type} className="mb-5">
            <div className="flex items-baseline justify-between pb-1">
              <h3 className="eyebrow">{DEBT_TYPE_LABEL[g.type] ?? g.type}</h3>
              <span className="num text-xs text-ink3">
                {g.items.length} · {fmt(g.items.reduce((t, d) => t + Number(d.current_balance ?? 0), 0))}
              </span>
            </div>
          <ol className="border border-rule">
            {g.items.map((d) => {
              const pct = Number(d.paid_off_pct ?? 0)
              return (
                <li key={d.id} className="bar-row">
                  <button className="w-full flex items-center gap-3 px-3 py-2.5 text-left"
                    onClick={() => setOpenId(openId === d.id ? null : d.id)}
                    aria-expanded={openId === d.id}>
                    <span className="num text-xs text-ink3 w-4 shrink-0">{rankOf(d.id)}</span>
                    <span className="flex-1 min-w-0">
                      <span className="block truncate text-[15px]">{d.name}</span>
                      <span className="eyebrow">
                        {d.apr != null && `${(Number(d.apr) * 100).toFixed(2)}% APR`}
                        {d.owner_name && ` · ${d.owner_name}`}
                      </span>
                      {/* Payoff progress, read left to right like a fuel gauge. */}
                      <span className="block mt-1.5 h-1 bg-rule" aria-hidden>
                        <span className="block h-full bg-moss"
                          style={{ width: `${Math.max(0, Math.min(100, pct * 100))}%` }} />
                      </span>
                    </span>
                    <span className="text-right shrink-0">
                      <span className="num block text-[15px]">{fmt(d.current_balance)}</span>
                      <span className="num text-xs text-ink3">
                        {d.debt_type === 'credit_card'
                          ? <>{fmt(d.available_credit)} open</>
                          : <>{(pct * 100).toFixed(0)}% paid</>}
                      </span>
                      {d.change_since_last != null && Number(d.change_since_last) !== 0 && (
                        <span className={`num block text-xs ${
                          Number(d.change_since_last) > 0 ? 'text-moss' : 'text-rust'}`}>
                          {Number(d.change_since_last) > 0 ? '↓' : '↑'}{' '}
                          {fmt(Math.abs(Number(d.change_since_last)))}
                        </span>
                      )}
                    </span>
                  </button>

                  {openId === d.id && (
                    <div className="px-3 pb-3 space-y-3">
                      <dl className="text-xs text-ink3 grid grid-cols-2 gap-x-4 gap-y-0.5">
                        <Row k={d.debt_type === 'credit_card' ? 'Credit limit' : 'Original amount'}
                             v={fmt(d.credit_limit)} />
                        <Row k={d.debt_type === 'credit_card' ? 'Available credit' : 'Paid to date'}
                             v={fmt(d.available_credit)} />
                        <Row k="Minimum payment" v={fmt(d.minimum_payment)} />
                        <Row k="Last updated" v={d.balance_as_of ? fmtDate(d.balance_as_of) : '—'} />
                        {d.previous_balance != null && (
                          <Row k={`Previous (${fmtDate(d.previous_as_of)})`}
                               v={fmt(d.previous_balance)} />
                        )}
                      </dl>

                      {isOwner && (
                        <>
                          <DebtBalanceForm debt={d} onDone={load} onError={setErr} />
                          <DebtTermsForm debt={d} onDone={load} onError={setErr} />
                        </>
                      )}
                    </div>
                  )}
                </li>
              )
            })}
          </ol>
          </section>
          ))}
        </div>

        {shown.length > 0 && (
          <>
            <UtilizationChart rows={shown} />
            <BalanceShareChart rows={shown} />
          </>
        )}
      </div>
    </>
  )
}
