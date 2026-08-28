import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { fmt } from '../lib/format'
import type { Funding } from '../lib/types'

const SOURCES = [
  { kind: 'from_savings',   label: 'From savings',  needs: 'saving' },
  { kind: 'line_of_credit', label: 'Credit line',   needs: 'debt' },
  { kind: 'bonus',          label: 'Bonus',         needs: null },
  { kind: 'tax_refund',     label: 'Tax refund',    needs: null },
] as const

export function AddFunds({
  periodId, rows, onChange, onError,
}: {
  periodId: number
  rows: Funding[]
  onChange: () => void
  onError: (m: string | null) => void
}) {
  const [open, setOpen] = useState(false)
  const [kind, setKind] = useState<string>('from_savings')
  const [amount, setAmount] = useState('')
  const [accountId, setAccountId] = useState<number | ''>('')
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)
  const [accounts, setAccounts] = useState<{ id: number; name: string; kind: string }[]>([])

  const needs = SOURCES.find((s) => s.kind === kind)?.needs ?? null

  useEffect(() => {
    if (!open) return
    supabase.from('account').select('id, name, kind').eq('is_active', true).order('name')
      .then(({ data }) => setAccounts((data ?? []) as typeof accounts))
  }, [open])

  useEffect(() => { setAccountId('') }, [kind])

  async function save() {
    setBusy(true); onError(null)
    const { error } = await supabase.rpc('add_funds', {
      p_period_id: periodId,
      p_kind: kind,
      p_amount: Number(amount),
      p_from_account_id: accountId === '' ? null : Number(accountId),
      p_received_on: null,
      p_note: note || null,
    })
    setBusy(false)
    if (error) return onError(error.message)
    setAmount(''); setNote(''); setOpen(false); onChange()
  }

  async function remove(id: number) {
    onError(null)
    const { error } = await supabase.rpc('remove_funds', { p_income_id: id })
    if (error) onError(error.message)
    else onChange()
  }

  const options = accounts.filter((a) => !needs || a.kind === needs)

  return (
    <section className="mt-6">
      <div className="flex items-baseline justify-between mb-1">
        <h2 className="eyebrow">Money moved in</h2>
        <button className="eyebrow hover:text-ink" onClick={() => setOpen((o) => !o)}>
          {open ? 'Cancel' : '+ Add funds'}
        </button>
      </div>

      {rows.length > 0 && (
        <ul className="border border-rule mb-2">
          {rows.map((f) => (
            <li key={f.id} className="bar-row flex items-center gap-3 px-3 py-2">
              <span className="flex-1 min-w-0">
                <span className="block text-[15px] truncate">
                  {SOURCES.find((s) => s.kind === f.kind)?.label ?? f.kind.replace(/_/g, ' ')}
                  {f.source_account && <span className="text-ink3"> · {f.source_account}</span>}
                </span>
                {f.notes && <span className="eyebrow">{f.notes}</span>}
              </span>
              <span className="num text-[15px]">{fmt(f.amount)}</span>
              <button onClick={() => remove(f.id)} aria-label="Remove"
                className="text-ink3 hover:text-rust px-1">×</button>
            </li>
          ))}
        </ul>
      )}

      {open && (
        <div className="border border-rule p-3 space-y-3">
          <div className="flex flex-wrap gap-2">
            {SOURCES.map((s) => (
              <button key={s.kind} onClick={() => setKind(s.kind)}
                className={`btn ${kind === s.kind ? 'bg-ink text-paper border-ink' : ''}`}>
                {s.label}
              </button>
            ))}
          </div>

          {needs && (
            <label className="block">
              <span className="eyebrow block mb-1">
                {needs === 'saving' ? 'Out of which savings' : 'Which credit line'}
              </span>
              <select className="field" value={accountId}
                onChange={(e) => setAccountId(e.target.value === '' ? '' : Number(e.target.value))}>
                <option value="">Not specified</option>
                {options.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}
              </select>
              {needs === 'debt' && (
                <span className="text-xs text-ink3 mt-1 block">
                  Drawing on a credit line adds to what you owe on it.
                </span>
              )}
            </label>
          )}

          <div className="grid grid-cols-2 gap-2">
            <label className="block">
              <span className="eyebrow block mb-1">Amount</span>
              <input className="field" inputMode="decimal" value={amount}
                onChange={(e) => setAmount(e.target.value)} />
            </label>
            <label className="block">
              <span className="eyebrow block mb-1">Note</span>
              <input className="field" value={note} onChange={(e) => setNote(e.target.value)} />
            </label>
          </div>

          <button className="btn-go" disabled={busy || !amount} onClick={save}>
            {busy ? 'Adding…' : 'Add funds'}
          </button>
        </div>
      )}
    </section>
  )
}
