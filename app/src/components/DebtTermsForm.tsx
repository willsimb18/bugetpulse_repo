import { useState } from 'react'
import { supabase } from '../lib/supabase'
import type { DebtStatus } from '../lib/types'

export function DebtTermsForm({
  debt, onDone, onError,
}: { debt: DebtStatus; onDone: () => void; onError: (m: string | null) => void }) {
  const [open, setOpen] = useState(false)
  const [limit, setLimit] = useState(String(debt.credit_limit ?? ''))
  const [apr, setApr] = useState(
    debt.apr != null ? String((Number(debt.apr) * 100).toFixed(2)) : '')
  const [minimum, setMinimum] = useState(String(debt.minimum_payment ?? ''))
  const [busy, setBusy] = useState(false)

  async function save() {
    setBusy(true); onError(null)
    const { error } = await supabase.rpc('update_debt_detail', {
      p_account_id: debt.id,
      p_credit_limit: limit ? Number(limit) : null,
      p_apr: apr ? Number(apr) : null,          // 24.99 or 0.2499 both fine
      p_minimum_payment: minimum ? Number(minimum) : null,
    })
    setBusy(false)
    if (error) return onError(error.message)
    setOpen(false); onDone()
  }

  if (!open) {
    return (
      <button className="eyebrow hover:text-ink" onClick={() => setOpen(true)}>
        Edit limit, rate &amp; minimum
      </button>
    )
  }

  return (
    <div className="space-y-2 pt-1">
      <p className="eyebrow">Terms</p>
      <div className="grid grid-cols-3 gap-2">
        <label className="block">
          <span className="eyebrow block mb-1">
            {debt.debt_type === 'credit_card' ? 'Limit' : 'Original'}
          </span>
          <input className="field py-1.5" inputMode="decimal" value={limit}
            onChange={(e) => setLimit(e.target.value)} />
        </label>
        <label className="block">
          <span className="eyebrow block mb-1">APR %</span>
          <input className="field py-1.5" inputMode="decimal" value={apr}
            onChange={(e) => setApr(e.target.value)} />
        </label>
        <label className="block">
          <span className="eyebrow block mb-1">Minimum</span>
          <input className="field py-1.5" inputMode="decimal" value={minimum}
            onChange={(e) => setMinimum(e.target.value)} />
        </label>
      </div>
      <div className="flex gap-2">
        <button className="btn-go" disabled={busy} onClick={save}>Save terms</button>
        <button className="btn" onClick={() => setOpen(false)}>Cancel</button>
      </div>
    </div>
  )
}
