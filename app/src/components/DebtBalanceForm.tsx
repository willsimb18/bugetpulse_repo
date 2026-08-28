import { useState } from 'react'
import { supabase } from '../lib/supabase'
import { fmt } from '../lib/format'
import type { DebtStatus } from '../lib/types'

type Mode = 'balance' | 'available' | 'paid'

// Which number is printed on the statement depends on the product, so let
// the entry match the paperwork instead of making you subtract.
const MODES: { v: Mode; label: string; help: string }[] = [
  { v: 'balance',   label: 'Balance owed',     help: 'What you still owe' },
  { v: 'available', label: 'Available credit', help: 'What you can still spend' },
  { v: 'paid',      label: 'Paid to date',     help: 'How much you have repaid' },
]

export function DebtBalanceForm({
  debt, onDone, onError,
}: { debt: DebtStatus; onDone: () => void; onError: (m: string | null) => void }) {
  const isCard = debt.debt_type === 'credit_card'
  const [mode, setMode] = useState<Mode>(isCard ? 'available' : 'balance')
  const [value, setValue] = useState('')
  const [asOf, setAsOf] = useState(new Date().toISOString().slice(0, 10))
  const [busy, setBusy] = useState(false)

  const limit = Number(debt.credit_limit ?? 0)
  const n = Number(value)
  const valid = value !== '' && !Number.isNaN(n)

  // Live preview of what this resolves to, so a typo is obvious before saving.
  const derivedBalance = !valid ? null
    : mode === 'balance' ? n
    : limit > 0 ? limit - n
    : null

  async function save() {
    setBusy(true); onError(null)
    const { error } = await supabase.rpc('record_debt_balance', {
      p_account_id: debt.id,
      p_balance:          mode === 'balance'   ? n : null,
      p_available_credit: mode === 'available' ? n : null,
      p_paid_to_date:     mode === 'paid'      ? n : null,
      p_as_of: asOf,
    })
    setBusy(false)
    if (error) return onError(error.message)
    setValue(''); onDone()
  }

  const noLimit = mode !== 'balance' && !(limit > 0)

  return (
    <div className="space-y-2 pt-1">
      <p className="eyebrow">Update from your statement</p>

      <div className="flex flex-wrap gap-1.5">
        {MODES.map((m) => (
          <button key={m.v} onClick={() => setMode(m.v)}
            className={`btn py-1 text-xs ${mode === m.v ? 'bg-ink text-paper border-ink' : ''}`}>
            {m.label}
          </button>
        ))}
      </div>

      <div className="flex flex-wrap items-end gap-2">
        <label className="flex-1 min-w-[7rem]">
          <span className="eyebrow block mb-1">
            {MODES.find((m) => m.v === mode)!.help}
          </span>
          <input className="field py-1.5" inputMode="decimal" value={value}
            onChange={(e) => setValue(e.target.value)} />
        </label>
        <label>
          <span className="eyebrow block mb-1">Statement date</span>
          <input className="field py-1.5" type="date" value={asOf}
            onChange={(e) => setAsOf(e.target.value)} />
        </label>
        <button className="btn-go" disabled={busy || !valid || noLimit} onClick={save}>
          {busy ? 'Saving…' : 'Save'}
        </button>
      </div>

      {noLimit && (
        <p className="text-xs text-amber">
          Set a credit limit or original loan amount before using this — there's nothing to
          subtract from.
        </p>
      )}

      {derivedBalance !== null && !noLimit && (
        <p className="text-xs text-ink3 num">
          {mode === 'balance'
            ? <>Available credit becomes {fmt(limit - n)}</>
            : <>Balance owed becomes {fmt(derivedBalance)}</>}
          {limit > 0 && <> · {((derivedBalance / limit) * 100).toFixed(0)}% of limit used</>}
        </p>
      )}
    </div>
  )
}
