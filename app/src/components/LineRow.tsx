import { useState } from 'react'
import { supabase } from '../lib/supabase'
import { fmt, fmtDate, urgencyOf } from '../lib/format'
import type { BudgetLine } from '../lib/types'

const dot: Record<string, string> = {
  paid: 'bg-moss', overdue: 'bg-rust', soon: 'bg-amber', upcoming: 'bg-rule',
}

export function LineRow({
  line, isOwner, editable, categoryAs, onChange, onError,
}: {
  line: BudgetLine
  isOwner: boolean
  /** Two ways of showing the category, so they can be compared. */
  categoryAs: 'subtitle' | 'column'
  /** False on a period that is not the one we are currently in. */
  editable: boolean
  onChange: () => void
  onError: (m: string | null) => void
}) {
  const [open, setOpen] = useState(false)
  const [busy, setBusy] = useState(false)
  const [amt, setAmt] = useState(String(line.amount_due))
  const u = urgencyOf(line.due_date, line.status)
  const paid = line.status === 'paid'

  async function call(fn: string, args: Record<string, unknown>) {
    setBusy(true)
    onError(null)
    const { error } = await supabase.rpc(fn, args)
    setBusy(false)
    if (error) onError(error.message)
    else { setOpen(false); onChange() }
  }

  return (
    <li className="bar-row">
      <div className="flex items-center gap-3 px-3 py-2.5">
        <span aria-hidden className={`w-1.5 h-1.5 shrink-0 rounded-full ${dot[u]}`} />

        <button
          onClick={() => setOpen((o) => !o)}
          aria-expanded={open}
          className="flex-1 text-left min-w-0"
        >
          <span className={`block truncate text-[15px] ${paid ? 'text-ink3 line-through' : ''}`}>
            {line.name}
          </span>
          {categoryAs === 'subtitle' && line.type_name && (
            <span className="block text-xs text-ink2 truncate">
              {line.type_name}
              {line.sub_type_name && <span className="text-ink3"> · {line.sub_type_name}</span>}
            </span>
          )}
          <span className="eyebrow block">
            {fmtDate(line.due_date)}
            {u === 'overdue' && !paid && <span className="text-rust"> · overdue</span>}
            {line.status === 'partial' && <span className="text-amber"> · part paid</span>}
            {line.amount_overridden && <span> · edited</span>}
          </span>
          {line.last_paid_amount != null && (
            <span className="eyebrow block normal-case tracking-normal">
              last paid <span className="num">{fmt(line.last_paid_amount)}</span>
              {line.last_paid_on && ` on ${fmtDate(line.last_paid_on)}`}
            </span>
          )}
        </button>

        {categoryAs === 'column' && (
          <span className="hidden sm:block w-32 shrink-0 text-xs text-ink2 truncate">
            {line.type_name ?? <span className="text-ink3">—</span>}
            {line.sub_type_name && (
              <span className="block text-ink3 truncate">{line.sub_type_name}</span>
            )}
          </span>
        )}

        <span className={`num text-[15px] shrink-0 ${paid ? 'text-ink3' : ''}`}>
          {fmt(paid || line.status === 'partial' ? line.amount_paid : line.amount_due)}
        </span>

        <button
          disabled={busy}
          onClick={() =>
            paid
              ? call('mark_unpaid', { p_line_id: line.id })
              : call('mark_paid', { p_line_id: line.id, p_amount: null, p_paid_on: null })
          }
          aria-label={paid ? `Mark ${line.name} unpaid` : `Mark ${line.name} paid`}
          className={`w-7 h-7 shrink-0 border grid place-items-center text-xs ${
            paid ? 'bg-moss border-moss text-paper' : 'bg-surface border-rule'
          }`}
        >
          {paid ? '✓' : ''}
        </button>
      </div>

      {open && (
        <div className="px-3 pb-3 pt-1 flex flex-wrap items-end gap-2">
          {isOwner && !editable ? (
            <p className="text-xs text-ink3">
              Amounts can only be changed during the pay period they belong to.
              {line.last_paid_amount != null && (
                <> This one last cost <span className="num">{fmt(line.last_paid_amount)}</span>
                  {line.last_paid_on && ` on ${fmtDate(line.last_paid_on)}`}.</>
              )}
            </p>
          ) : isOwner ? (
            <>
              <label className="flex-1 min-w-[8rem]">
                <span className="eyebrow block mb-1">
                  Amount this period
                  {line.last_paid_amount != null && (
                    <span className="normal-case tracking-normal">
                      {' · last '}<span className="num">{fmt(line.last_paid_amount)}</span>
                    </span>
                  )}
                </span>
                <input
                  className="field py-1.5"
                  inputMode="decimal"
                  value={amt}
                  onChange={(e) => setAmt(e.target.value)}
                />
              </label>
              <button
                className="btn-go"
                disabled={busy}
                onClick={() =>
                  call('set_line_amount', {
                    p_line_id: line.id, p_amount: Number(amt),
                    p_remember: false, p_cascade: true,
                  })
                }
              >
                Save
              </button>
              <button
                className="btn"
                disabled={busy}
                onClick={() =>
                  call('set_line_amount', {
                    p_line_id: line.id, p_amount: Number(amt),
                    p_remember: false, p_cascade: false,
                  })
                }
              >
                This period only
              </button>
              {line.amount_overridden && line.account_id && (
                <button className="btn" disabled={busy}
                  onClick={() => call('reset_line_amount', { p_line_id: line.id })}>
                  Reset
                </button>
              )}
            </>
          ) : (
            <>
              <label className="flex-1 min-w-[8rem]">
                <span className="eyebrow block mb-1">Paid a different amount?</span>
                <input
                  className="field py-1.5"
                  inputMode="decimal"
                  value={amt}
                  onChange={(e) => setAmt(e.target.value)}
                />
              </label>
              <button
                className="btn-go"
                disabled={busy}
                onClick={() =>
                  call('mark_paid', {
                    p_line_id: line.id, p_amount: Number(amt), p_paid_on: null,
                  })
                }
              >
                Record payment
              </button>
            </>
          )}
        </div>
      )}
    </li>
  )
}
