import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { Empty, Err } from '../components/Chrome'
import { dueOnLabel, fmt, fmtDate, KIND_LABEL, scheduleField } from '../lib/format'
import type { AccountAdmin, AccountKind, AmountMode } from '../lib/types'
import { NewAccount } from '../components/NewAccount'

const MODE_HELP: Record<AmountMode, string> = {
  carry_forward: 'Repeats what you last paid',
  fixed: 'Always the set amount',
  percent_of_income: 'A share of the period income',
  split_monthly: 'A monthly figure, split across the paychecks in the month',
}

export function Bills({ isOwner }: { isOwner: boolean }) {
  const [rows, setRows] = useState<AccountAdmin[]>([])
  const [err, setErr] = useState<string | null>(null)
  const [openId, setOpenId] = useState<number | null>(null)
  const [showInactive, setShowInactive] = useState(false)
  const [kindFilter, setKindFilter] = useState<AccountKind | 'all'>('all')
  const [query, setQuery] = useState('')
  const [cats, setCats] = useState<{ id: number; full_name: string }[]>([])
  // Expense accounts that are actually on this period's budget.
  const [onBudget, setOnBudget] = useState<Set<number> | null>(null)
  const [busy, setBusy] = useState(false)
  const [adding, setAdding] = useState<AccountKind | null>(null)

  const load = useCallback(async () => {
    const { data, error } = await supabase
      .from('v_account_admin').select('*').order('kind').order('name')
    if (error) setErr(error.message)
    setRows((data ?? []) as AccountAdmin[])
  }, [])

  useEffect(() => { void load() }, [load])

  useEffect(() => {
    void supabase.from('v_category_picker').select('id, full_name')
      .order('full_name')
      .then(({ data }) => setCats((data ?? []) as typeof cats))
  }, [])

  /*
   * The import brought across 286 expense accounts, and since migration 16
   * an expense only reaches a period if someone put it there. Listing all
   * 286 under Expenses is a catalogue, not a budget — so that section is
   * narrowed to the ones on the current period.
   *
   * Nothing is deleted. Every account and all its history stay exactly
   * where they are; this is the Bills page choosing what to show.
   */
  useEffect(() => {
    void (async () => {
      const today = new Date().toISOString().slice(0, 10)
      const { data: p } = await supabase
        .from('budget_period').select('id')
        .lte('period_start', today).gte('period_end', today)
        .order('period_start').limit(1)
      const period = (p ?? [])[0] as { id: number } | undefined
      if (!period) { setOnBudget(new Set()); return }

      const { data: l } = await supabase
        .from('budget_line').select('account_id')
        .eq('budget_period_id', period.id)
        .not('account_id', 'is', null)
      setOnBudget(new Set(((l ?? []) as { account_id: number }[])
        .map((r) => r.account_id)))
    })()
  }, [])

  async function call(fn: string, args: Record<string, unknown>) {
    setBusy(true); setErr(null)
    const { error } = await supabase.rpc(fn, args)
    setBusy(false)
    if (error) setErr(error.message)
    else void load()
  }

  const q = query.trim().toLowerCase()
  const matches = (r: AccountAdmin) =>
    !q ||
    r.name.toLowerCase().includes(q) ||
    (r.type_name ?? '').toLowerCase().includes(q) ||
    (r.sub_type_name ?? '').toLowerCase().includes(q)

  // is_always_due expenses stay listed whether or not this period has
  // materialised yet — they are on every period by definition.
  const currentExpense = (r: AccountAdmin) =>
    r.kind !== 'expense' || onBudget === null
      || r.is_always_due || onBudget.has(r.id)

  const visible = rows.filter(
    (r) => (showInactive || r.is_active)
        && (kindFilter === 'all' || r.kind === kindFilter)
        && matches(r)
        && currentExpense(r),
  )

  const hiddenExpenses = onBudget === null ? 0 : rows.filter(
    (r) => r.kind === 'expense' && (showInactive || r.is_active)
        && matches(r) && !currentExpense(r)).length

  // Fixed order, so a section never jumps position when another empties.
  const KIND_ORDER: AccountKind[] = ['bill', 'expense', 'debt', 'saving']
  const groups = KIND_ORDER
    .map((kind) => ({ kind, items: visible.filter((a) => a.kind === kind) }))
    .filter((g) => g.items.length > 0)

  // Counts come off the unfiltered rows, so the dropdown can say what is
  // behind an option you haven't picked yet.
  const countOf = (k: AccountKind) =>
    rows.filter((r) => (showInactive || r.is_active) && r.kind === k
                    && matches(r) && currentExpense(r)).length

  return (
    <>
      <div className="flex items-baseline justify-between gap-3 pt-5 pb-2">
        <h2 className="text-lg font-medium">Bills &amp; Accounts</h2>

        <div className="flex items-center gap-3 shrink-0">
          <label className="flex items-center gap-1.5">
            <span className="eyebrow">Type</span>
            <select
              className="border border-rule bg-surface px-2 py-1 text-xs"
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

      <div className="flex items-center gap-2 pb-3">
        <input
          type="search"
          className="field py-1.5 text-sm font-sans"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Search bills and accounts…"
          aria-label="Search bills and accounts"
        />
        {q && (
          <span className="eyebrow shrink-0 whitespace-nowrap">
            {visible.length} match{visible.length === 1 ? '' : 'es'}
          </span>
        )}
      </div>

      {isOwner && (
        <div className="flex flex-wrap gap-2 pb-3">
          {/* Expenses are added from the Budget tab, against a period. */}
          {(['bill', 'saving'] as AccountKind[]).map((k) => (
            <button key={k} className={`btn ${adding === k ? 'bg-ink text-paper border-ink' : ''}`}
              onClick={() => setAdding(adding === k ? null : k)}>
              + {k === 'bill' ? 'Bill' : 'Savings'}
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
          {q
            ? `Nothing matching “${query.trim()}”.`
            : kindFilter === 'all'
              ? 'No accounts yet.'
              : `No ${KIND_LABEL[kindFilter].toLowerCase()} to show.`}
        </Empty>
      )}

      {hiddenExpenses > 0 && (
        <p className="text-xs text-ink3 pb-3">
          {hiddenExpenses} other expense{hiddenExpenses === 1 ? '' : 's'} are on
          file but not on this period. They are still there — add one to a
          period from the Budget tab, or tick “Always due” to have it appear
          every time.
        </p>
      )}

      {groups.map((g) => (
      <section key={g.kind} className="mb-5">
        <div className="flex items-baseline justify-between pb-1">
          <h3 className="eyebrow">{KIND_LABEL[g.kind]}</h3>
          <span className="num text-xs text-ink3">
            {g.items.length} · {fmt(g.items.reduce((t, a) => t + Number(a.default_amount), 0))}
          </span>
        </div>
      <div className="flex items-center gap-3 px-3 pb-1 text-[10px] uppercase
                      tracking-[0.14em] text-ink3 font-medium">
        <span className="flex-1 min-w-0">Name</span>
        <span className="hidden sm:block w-32 shrink-0">Category</span>
        <span className="hidden md:block w-24 shrink-0">Due on</span>
        <span className="w-28 shrink-0 text-right">Amount</span>
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
                </span>
              </span>

              <span className="hidden sm:block w-32 shrink-0 text-xs text-ink2 truncate">
                {a.type_name ?? <span className="text-ink3">—</span>}
                {a.sub_type_name && (
                  <span className="block text-ink3 truncate">{a.sub_type_name}</span>
                )}
              </span>

              <span className="hidden md:block w-24 shrink-0 text-xs text-ink2 truncate">
                {dueOnLabel(a)}
              </span>

              <span className="num text-[15px] w-28 shrink-0 text-right">
                {fmt(a.default_amount)}
              </span>
            </button>

            {openId === a.id && (
              <div className="px-3 pb-3 space-y-3">
                <p className="text-xs text-ink3">
                  {MODE_HELP[a.amount_mode]}
                  {a.amount_mode === 'split_monthly' &&
                    ' — the amount below is the whole month'}
                  {a.last_paid_on && ` · last paid ${fmt(a.last_paid_amount)} on ${fmtDate(a.last_paid_on)}`}
                  {` · ${a.open_lines} open`}
                </p>

                {!isOwner ? (
                  <p className="text-xs text-ink3">Only an owner can change these.</p>
                ) : (
                  <>
                    <CategoryEditor account={a} cats={cats} busy={busy} onSave={call} />

                    <ScheduleEditor account={a} busy={busy} onSave={call} />

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
                        <option value="split_monthly">Split monthly across paychecks</option>
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

/*
 * Which category an account belongs to.
 *
 * The value shown is the account's own category_id, which v_account_admin
 * does not return — it returns the resolved names instead. So the current
 * selection is matched on the full name it renders, and "Uncategorised"
 * is a real choice rather than an empty box.
 */
function CategoryEditor({
  account, cats, busy, onSave,
}: {
  account: AccountAdmin
  cats: { id: number; full_name: string }[]
  busy: boolean
  onSave: (fn: string, args: Record<string, unknown>) => void
}) {
  const current = account.sub_type_name
    ? `${account.type_name} / ${account.sub_type_name}`
    : account.type_name ?? ''
  const [value, setValue] = useState<string>(
    String(cats.find((c) => c.full_name === current)?.id ?? ''))

  useEffect(() => {
    setValue(String(cats.find((c) => c.full_name === current)?.id ?? ''))
  }, [cats, current])

  return (
    <div className="flex flex-wrap items-end gap-2">
      <label className="flex-1 min-w-[10rem]">
        <span className="eyebrow block mb-1">Category</span>
        <select className="field py-1.5" value={value} disabled={busy}
          onChange={(e) => setValue(e.target.value)}>
          <option value="">Uncategorised</option>
          {cats.map((c) => (
            <option key={c.id} value={c.id}>{c.full_name}</option>
          ))}
        </select>
      </label>
      <button className="btn" disabled={busy}
        onClick={() => onSave('set_account_category', {
          p_account_id: account.id,
          p_category_id: value === '' ? null : Number(value),
        })}>
        Save category
      </button>
    </div>
  )
}

/*
 * Editing when a bill is due.
 *
 * Which field to offer depends on the cadence: monthly and its relatives
 * are a day of the month, weekly and biweekly count from an anchor date,
 * per_paycheck has no date of its own at all. Offering a day-of-month box
 * for a biweekly account would write a value the schedule never reads.
 *
 * reschedule_account does the rest — it rewrites the unpaid lines in open
 * periods onto the new dates, so the change shows on the budget straight
 * away rather than at the next nightly run.
 */
function ScheduleEditor({
  account, busy, onSave,
}: {
  account: AccountAdmin
  busy: boolean
  onSave: (fn: string, args: Record<string, unknown>) => void
}) {
  const field = account.kind === 'expense' || account.kind === 'saving'
    ? 'none' : scheduleField(account.frequency)
  const [day, setDay] = useState(String(account.due_day ?? ''))
  const [anchor, setAnchor] = useState(account.anchor_date ?? '')

  if (field === 'none') {
    return (
      <p className="text-xs text-ink3">
        {account.kind === 'expense'
          ? 'Expenses are added to a period as they come up, so there is no due date.'
          : account.kind === 'saving'
            ? 'Savings go in with the paycheck, so there is no due date.'
            : 'Due every pay period, so there is no date to set.'}
      </p>
    )
  }

  return (
    <div className="flex flex-wrap items-end gap-2">
      {field === 'due_day' ? (
        <label className="min-w-[7rem]">
          <span className="eyebrow block mb-1">Due on day</span>
          <input className="field py-1.5" inputMode="numeric" value={day}
            onChange={(e) => setDay(e.target.value)} placeholder="16" />
        </label>
      ) : (
        <label className="min-w-[10rem]">
          <span className="eyebrow block mb-1">Counting from</span>
          <input className="field py-1.5" type="date" value={anchor}
            onChange={(e) => setAnchor(e.target.value)} />
        </label>
      )}

      <button
        className="btn"
        disabled={busy || (field === 'due_day'
          ? !(Number(day) >= 1 && Number(day) <= 31)
          : !anchor)}
        onClick={() => onSave('reschedule_account', {
          p_account_id: account.id,
          ...(field === 'due_day'
            ? { p_due_day: Number(day) }
            : { p_anchor_date: anchor }),
        })}
      >
        Save due date
      </button>

      <span className="eyebrow self-center">
        currently {dueOnLabel(account)}
      </span>
    </div>
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
