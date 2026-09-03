import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { Empty, Err } from '../components/Chrome'
import { fmt, fmtDate } from '../lib/format'
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

  const load = useCallback(async () => {
    const { data, error } = await supabase.from('v_debt_status').select('*')
    if (error) setErr(error.message)
    setRows((data ?? []) as DebtStatus[])
  }, [])

  useEffect(() => { void load() }, [load])

  const sorted = [...rows].sort((a, b) =>
    strategy === 'avalanche' ? a.avalanche_rank - b.avalanche_rank : a.snowball_rank - b.snowball_rank)

  const total = rows.reduce((s, r) => s + Number(r.current_balance ?? 0), 0)

  return (
    <>
      <div className="pt-5 pb-1">
        <p className="eyebrow">Total owed</p>
        <p className="num text-[34px] leading-none mt-1">{fmt(total)}</p>
      </div>

      <Err msg={err} />

      {adding && (
        <NewAccount kind="debt" onError={setErr}
          onCancel={() => setAdding(false)}
          onDone={() => { setAdding(false); void load() }} />
      )}

      {/*
        Payoff order on the left, dashboard on the right. One column until
        there is room for two — the charts stack under the list on a phone
        rather than being squeezed beside it.
      */}
      <div className="grid gap-x-8 gap-y-6 items-start lg:grid-cols-[minmax(0,23rem)_minmax(0,1fr)]">
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

          {sorted.length === 0 && !adding && <Empty>No debts tracked yet.</Empty>}

          <ol className="border border-rule">
            {sorted.map((d, i) => {
              const pct = Number(d.paid_off_pct ?? 0)
              return (
                <li key={d.id} className="bar-row">
                  <button className="w-full flex items-center gap-3 px-3 py-2.5 text-left"
                    onClick={() => setOpenId(openId === d.id ? null : d.id)}
                    aria-expanded={openId === d.id}>
                    <span className="num text-xs text-ink3 w-4 shrink-0">{i + 1}</span>
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
        </div>

        {rows.length > 0 && (
          <aside className="min-w-0 grid gap-4 items-start lg:grid-cols-2 lg:pt-4">
            <UtilizationChart rows={rows} />
            <BalanceShareChart rows={rows} />
          </aside>
        )}
      </div>
    </>
  )
}
