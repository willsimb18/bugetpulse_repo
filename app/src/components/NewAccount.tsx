import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { AccountKind, AmountMode } from '../lib/types'

interface Cat { id: number; full_name: string; is_parent: boolean }

const FREQS = [
  { v: 'per_paycheck', label: 'Every paycheck' },
  { v: 'weekly',       label: 'Weekly' },
  { v: 'biweekly',     label: 'Every 2 weeks' },
  { v: 'monthly',      label: 'Monthly' },
  { v: 'quarterly',    label: 'Quarterly' },
  { v: 'annual',       label: 'Yearly' },
  { v: 'one_time',     label: 'One time' },
]

const NEEDS_DAY = ['monthly', 'quarterly', 'semiannual', 'annual', 'semimonthly']
const NEEDS_DATE = ['weekly', 'biweekly', 'one_time']

export function NewAccount({
  kind, onDone, onCancel, onError,
}: {
  kind: AccountKind
  onDone: () => void
  onCancel: () => void
  onError: (m: string | null) => void
}) {
  const [name, setName] = useState('')
  const [amount, setAmount] = useState('')
  const [frequency, setFrequency] = useState(
    kind === 'expense' || kind === 'saving' ? 'per_paycheck' : 'monthly')
  const [dueDay, setDueDay] = useState('')
  const [anchor, setAnchor] = useState(new Date().toISOString().slice(0, 10))
  const [alwaysDue, setAlwaysDue] = useState(false)
  const [mode, setMode] = useState<AmountMode>(
    kind === 'debt' || kind === 'saving' ? 'fixed' : 'carry_forward')
  const [percent, setPercent] = useState('10')
  const [categoryId, setCategoryId] = useState<number | ''>('')
  const [cats, setCats] = useState<Cat[]>([])
  const [newCat, setNewCat] = useState('')

  // debt-only
  const [debtType, setDebtType] = useState('credit_card')
  const [limit, setLimit] = useState('')
  const [apr, setApr] = useState('')
  const [minimum, setMinimum] = useState('')
  const [balance, setBalance] = useState('')

  const [busy, setBusy] = useState(false)

  const loadCats = () =>
    supabase.from('v_category_picker').select('id, full_name, is_parent')
      .order('full_name').then(({ data }) => setCats((data ?? []) as Cat[]))

  useEffect(() => { void loadCats() }, [])

  async function addCategory() {
    if (!newCat.trim()) return
    setBusy(true); onError(null)
    const { data, error } = await supabase.rpc('create_category', { p_name: newCat.trim() })
    setBusy(false)
    if (error) return onError(error.message)
    setNewCat('')
    await loadCats()
    if (data?.id) setCategoryId(data.id)
  }

  async function save() {
    setBusy(true); onError(null)
    const { error } = await supabase.rpc('create_account', {
      p_name: name,
      p_kind: kind,
      p_frequency: frequency,
      p_amount: Number(amount || 0),
      p_category_id: categoryId === '' ? null : Number(categoryId),
      p_due_day: NEEDS_DAY.includes(frequency) && dueDay ? Number(dueDay) : null,
      p_anchor_date: NEEDS_DATE.includes(frequency) ? anchor : null,
      p_always_due: alwaysDue,
      p_amount_mode: mode,
      p_amount_percent: mode === 'percent_of_income' ? Number(percent) / 100 : null,
      ...(kind === 'debt' ? {
        p_debt_type: debtType,
        p_credit_limit: limit ? Number(limit) : null,
        p_apr: apr ? Number(apr) : null,
        p_minimum_payment: minimum ? Number(minimum) : null,
        p_opening_balance: balance ? Number(balance) : null,
      } : {}),
    })
    setBusy(false)
    if (error) return onError(error.message)
    onDone()
  }

  const noun = kind === 'debt' ? 'debt' : kind === 'saving' ? 'savings goal'
             : kind === 'expense' ? 'expense' : 'bill'

  return (
    <div className="border border-rule p-3 space-y-3 mb-3">
      <p className="eyebrow">New {noun}</p>

      <div className="grid grid-cols-2 gap-2">
        <label className="block col-span-2">
          <span className="eyebrow block mb-1">Name</span>
          <input className="field" value={name} onChange={(e) => setName(e.target.value)}
            placeholder={kind === 'debt' ? 'Visa · Suncoast' : 'Water'} />
        </label>

        <label className="block">
          <span className="eyebrow block mb-1">
            {kind === 'debt' ? 'Monthly payment' : 'Amount'}
          </span>
          <input className="field" inputMode="decimal" value={amount}
            onChange={(e) => setAmount(e.target.value)} />
        </label>

        <label className="block">
          <span className="eyebrow block mb-1">How often</span>
          <select className="field" value={frequency}
            onChange={(e) => setFrequency(e.target.value)}>
            {FREQS.map((f) => <option key={f.v} value={f.v}>{f.label}</option>)}
          </select>
        </label>

        {NEEDS_DAY.includes(frequency) && !alwaysDue && (
          <label className="block">
            <span className="eyebrow block mb-1">Day of month due</span>
            <input className="field" inputMode="numeric" value={dueDay}
              onChange={(e) => setDueDay(e.target.value)} placeholder="1–31" />
          </label>
        )}
        {NEEDS_DATE.includes(frequency) && !alwaysDue && (
          <label className="block">
            <span className="eyebrow block mb-1">First due on</span>
            <input className="field" type="date" value={anchor}
              onChange={(e) => setAnchor(e.target.value)} />
          </label>
        )}
      </div>

      <label className="block">
        <span className="eyebrow block mb-1">Category</span>
        <select className="field" value={categoryId}
          onChange={(e) => setCategoryId(e.target.value === '' ? '' : Number(e.target.value))}>
          <option value="">None</option>
          {cats.map((c) => <option key={c.id} value={c.id}>{c.full_name}</option>)}
        </select>
      </label>

      <div className="flex gap-2 items-end">
        <label className="flex-1">
          <span className="eyebrow block mb-1">Or add a new category</span>
          <input className="field py-1.5" value={newCat}
            onChange={(e) => setNewCat(e.target.value)} placeholder="Utilities" />
        </label>
        <button className="btn" disabled={busy || !newCat.trim()} onClick={addCategory}>Add</button>
      </div>

      {kind !== 'debt' && (
        <>
          <label className="block">
            <span className="eyebrow block mb-1">How the amount is decided</span>
            <select className="field" value={mode}
              onChange={(e) => setMode(e.target.value as AmountMode)}>
              <option value="carry_forward">Carry forward last payment</option>
              <option value="fixed">Fixed amount</option>
              <option value="percent_of_income">Percent of income</option>
            </select>
          </label>
          {mode === 'percent_of_income' && (
            <label className="block">
              <span className="eyebrow block mb-1">Percent of net income</span>
              <input className="field" inputMode="decimal" value={percent}
                onChange={(e) => setPercent(e.target.value)} />
            </label>
          )}
        </>
      )}

      {kind === 'debt' && (
        <div className="grid grid-cols-2 gap-2">
          <label className="block col-span-2">
            <span className="eyebrow block mb-1">Type</span>
            <select className="field" value={debtType} onChange={(e) => setDebtType(e.target.value)}>
              <option value="credit_card">Credit card</option>
              <option value="auto_loan">Auto loan</option>
              <option value="mortgage">Mortgage</option>
              <option value="personal_loan">Personal loan</option>
              <option value="student_loan">Student loan</option>
              <option value="other">Other</option>
            </select>
          </label>
          <label className="block">
            <span className="eyebrow block mb-1">
              {debtType === 'credit_card' ? 'Credit limit' : 'Original amount'}
            </span>
            <input className="field" inputMode="decimal" value={limit}
              onChange={(e) => setLimit(e.target.value)} />
          </label>
          <label className="block">
            <span className="eyebrow block mb-1">APR %</span>
            <input className="field" inputMode="decimal" value={apr}
              onChange={(e) => setApr(e.target.value)} placeholder="13.09" />
          </label>
          <label className="block">
            <span className="eyebrow block mb-1">Minimum payment</span>
            <input className="field" inputMode="decimal" value={minimum}
              onChange={(e) => setMinimum(e.target.value)} />
          </label>
          <label className="block">
            <span className="eyebrow block mb-1">Balance owed now</span>
            <input className="field" inputMode="decimal" value={balance}
              onChange={(e) => setBalance(e.target.value)} />
          </label>
        </div>
      )}

      <label className="flex items-center gap-2 text-sm cursor-pointer">
        <input type="checkbox" checked={alwaysDue}
          onChange={(e) => setAlwaysDue(e.target.checked)} />
        Always due — include it every pay period
      </label>

      <div className="flex gap-2">
        <button className="btn-go" disabled={busy || !name.trim()} onClick={save}>
          {busy ? 'Saving…' : `Add ${noun}`}
        </button>
        <button className="btn" onClick={onCancel}>Cancel</button>
      </div>
    </div>
  )
}
