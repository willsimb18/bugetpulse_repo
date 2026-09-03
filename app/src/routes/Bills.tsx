import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { Empty, Err } from '../components/Chrome'
import { fmt, fmtDate, KIND_LABEL } from '../lib/format'
import type { AccountAdmin, AccountKind, AmountMode } from '../lib/types'
import { NewAccount } from '../components/NewAccount'

const MODE_HELP: Record<AmountMode, string> = {
  carry_forward: 'Repeats what you last paid',
  fixed: 'Always the set amount',
  percent_of_income: 'A share of the period income',
}

export function Bills({ isOwner }: { isOwner: boolean }) {
  const [rows, setRows] = useState<AccountAdmin[]>([])
  const [err, setErr] = useState<string | null>(null)
  const [openId, setOpenId] = useState<number | null>(null)
  const [showInactive, setShowInactive] = useState(false)
  const [kindFilter, setKindFilter] = useState<AccountKind | 'all'>('all')
  const [busy, setBusy] = useState(false)
  const [adding, setAdding] = useState<AccountKind | null>(null)

  const load = useCallback(async () => {
    const { data, error } = await supabase
      .from('v_account_admin').select('*').order('kind').order('name')
    if (error) setErr(error.message)
    setRows((data ?? []) as AccountAdmin[])
  }, [])

  useEffect(() => { void load() }, [load])

  async function call(fn: string, args: Record<string, unknown>) {
    setBusy(true); setErr(null)
    const { error } = await supabase.rpc(fn, args)
    setBusy(false)
    if (error) setErr(error.message)
    else void load()
  }

  const visible = rows.filter(
    (r) => (showInactive || r.is_active) && (kindFilter === 'all' || r.kind === kindFilter),
  )

  // Fixed order, so a section never jumps position when another empties.
  const KIND_ORDER: AccountKind[] = ['bill', 'expense', 'debt', 'saving']
  const groups = KIND_ORDER
    .map((kind) => ({ kind, items: visible.filter((a) => a.kind === kind) }))
    .filter((g) => g.items.length > 0)

  // Counts come off the unfiltered rows, so the dropdown can say what is
  // behind an option you haven't picked yet.
  const countOf = (k: AccountKind) =>
    rows.filter((r) => (showInactive || r.is_active) && r.kind === k).length

  return (
    <>
      <div className="flex items-baseline justify-between gap-3 pt-5 pb-2">
        <h2 className="text-lg font-medium">Bills &amp; Accounts</h2>

        <div className="flex items-center gap-3 shrink-0">
          <label className="flex items-center gap-1.5">
            <span className="eyebrow">Type</span>
            <select
              className="border border-rule bg-white px-2 py-1 text-xs"
              value={kindFilter}
              onChange={(e) => setKindFilter(e.target.value as AccountKind | 'all')}
            >
              <option value="all">
                All ({KIND_ORDER.reduce((t, k) => t + countOf(k), 0)})
              </option>
              {KIND_ORDER.map((k) => (
                <option key={k} value={k}>{KIND_LABEL[k]} ({countOf(k)})</option>
              ))}
            </select>
          </label>

          <label className="eyebrow flex items-center gap-1.5 cursor-pointer">
            <input type="checkbox" checked={showInactive}
              onChange={(e) => setShowInactive(e.target.checked)} />
            Show inactive
          </label>
        </div>
      </div>

      {isOwner && (
        <div className="flex flex-wrap gap-2 pb-3">
          {(['bill', 'expense', 'saving'] as AccountKind[]).map((k) => (
            <button key={k} className={`btn ${adding === k ? 'bg-ink text-paper border-ink' : ''}`}
              onClick={() => setAdding(adding === k ? null : k)}>
              + {k === 'bill' ? 'Bill' : k === 'expense' ? 'Expense' : 'Savings'}
            </button>
          ))}
        </div>
      )}

      <Err msg={err} />

      {adding && (
        <NewAccount kind={adding} onError={setErr}
          onCancel={() => setAdding(null)}
          onDone={() => { setAdding(null); void load() }} />
      )}
      {visible.length === 0 && (
        <Empty>
          {kindFilter === 'all'
            ? 'No accounts yet.'
            : `No ${KIND_LABEL[kindFilter].toLowerCase()} to show.`}
        </Empty>
      )}

      {groups.map((g) => (
      <section key={g.kind} className="mb-5">
        <div className="flex items-baseline justify-between pb-1">
          <h3 className="eyebrow">{KIND_LABEL[g.kind]}</h3>
          <span className="num text-xs text-ink3">
            {g.items.length} · {fmt(g.items.reduce((t, a) => t + Number(a.default_amount), 0))}
          </span>
        </div>
      <ul className="border border-rule">
        {g.items.map((a) => (
          <li key={a.id} className="bar-row">
            <button
              onClick={() => setOpenId(openId === a.id ? null : a.id)}
              aria-expanded={openId === a.id}
              className="w-full flex items-center gap-3 px-3 py-2.5 text-left"
            >
              <span className="flex-1 min-w-0">
                <span className={`block truncate text-[15px] ${a.is_active ? '' : 'text-ink3 line-through'}`}>
                  {a.name}
                </span>
                <span className="eyebrow">
                  {KIND_LABEL[a.kind]} · {a.frequency.replace(/_/g, ' ')}
                  {a.is_always_due && ' · always due'}
                </span>
              </span>
              <span className="num text-[15px]">{fmt(a.default_amount)}</span>
            </button>

            {openId === a.id && (
              <div className="px-3 pb-3 space-y-3">
                <p className="text-xs text-ink3">
                  {MODE_HELP[a.amount_mode]}
                  {a.last_paid_on && ` · last paid ${fmt(a.last_paid_amount)} on ${fmtDate(a.last_paid_on)}`}
                  {` · ${a.open_lines} open`}
                </p>

                {!isOwner ? (
                  <p className="text-xs text-ink3">Only an owner can change these.</p>
                ) : (
                  <>
                    <AmountEditor busy={busy} value={a.default_amount}
                      onSave={(v, applyOpen) =>
                        call('update_account_amount', {
                          p_account_id: a.id, p_new_amount: v, p_apply_to_open: applyOpen,
                        })} />

                    <label className="flex items-center gap-2 text-sm cursor-pointer">
                      <input
                        type="checkbox" checked={a.is_always_due} disabled={busy}
                        onChange={(e) =>
                          call('set_always_due', { p_account_id: a.id, p_on: e.target.checked })}
                      />
                      Always due — include every pay period
                    </label>

                    <label className="block">
                      <span className="eyebrow block mb-1">How the amount is decided</span>
                      <select
                        className="field" value={a.amount_mode} disabled={busy}
                        onChange={(e) =>
                          call('set_amount_mode', {
                            p_account_id: a.id,
                            p_mode: e.target.value,
                            p_percent: e.target.value === 'percent_of_income'
                              ? (a.amount_percent ?? 0.1) : null,
                          })}
                      >
                        <option value="carry_forward">Carry forward last payment</option>
                        <option value="fixed">Fixed amount</option>
                        <option value="percent_of_income">Percent of income</option>
                      </select>
                    </label>

                    <button
                      className="btn" disabled={busy}
                      onClick={() =>
                        a.is_active
                          ? call('deactivate_account', {
                              p_account_id: a.id, p_effective: null, p_note: null })
                          : call('reactivate_account', { p_account_id: a.id })}
                    >
                      {a.is_active ? 'Stop tracking this bill' : 'Start tracking again'}
                    </button>
                  </>
                )}
              </div>
            )}
          </li>
        ))}
      </ul>
      </section>
      ))}
    </>
  )
}

function AmountEditor({
  value, busy, onSave,
}: { value: number; busy: boolean; onSave: (v: number, applyOpen: boolean) => void }) {
  const [v, setV] = useState(String(value))
  return (
    <div className="flex flex-wrap items-end gap-2">
      <label className="flex-1 min-w-[8rem]">
        <span className="eyebrow block mb-1">Amount</span>
        <input className="field py-1.5" inputMode="decimal"
          value={v} onChange={(e) => setV(e.target.value)} />
      </label>
      <button className="btn-go" disabled={busy} onClick={() => onSave(Number(v), true)}>
        Save &amp; update open
      </button>
      <button className="btn" disabled={busy} onClick={() => onSave(Number(v), false)}>
        Future only
      </button>
    </div>
  )
}
