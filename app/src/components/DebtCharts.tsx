import { useState } from 'react'
import { fmt, fmtDate } from '../lib/format'
import type { DebtStatus } from '../lib/types'

/*
 * Two charts, rebuilt from the "Creditcards-Loans debt view" tab.
 *
 * Both are single-hue on purpose. The app's palette is a deliberately
 * desaturated ledger green, and running it through a categorical-palette
 * check fails hard: moss and slate sit ΔE 10 apart for normal vision and
 * under 6 for deuteranopia. Eleven accounts can never be told apart by
 * colour here, so identity is carried by the row label and magnitude by
 * bar length. The only colour that means anything is over-vs-under target,
 * and that always ships with words next to it rather than standing alone.
 */

const pct = (n: number) => `${(n * 100).toFixed(0)}%`

/* Shared row scaffolding: label, bar, figures. */
function BarRow({
  label, sub, width, over, children, onHover, hovered,
}: {
  label: string
  sub?: string
  width: number            // 0..1 of the track
  over?: boolean
  children: React.ReactNode
  onHover?: (on: boolean) => void
  hovered?: boolean
}) {
  return (
    <li
      className={`px-3 py-2 ${hovered ? 'bg-bar' : ''}`}
      onMouseEnter={() => onHover?.(true)}
      onMouseLeave={() => onHover?.(false)}
    >
      <div className="flex items-baseline justify-between gap-3">
        <span className="text-[13px] truncate min-w-0">{label}</span>
        <span className="num text-xs text-ink3 shrink-0">{children}</span>
      </div>
      <div className="relative mt-1.5 h-2 bg-rule/40" aria-hidden>
        <div
          className={`absolute inset-y-0 left-0 ${over ? 'bg-rust' : 'bg-slate'}`}
          style={{ width: `${Math.max(0, Math.min(100, width * 100))}%` }}
        />
      </div>
      {sub && <p className="eyebrow mt-1 normal-case tracking-normal">{sub}</p>}
    </li>
  )
}

/* ------------------------------------------------------------------ *
 * 1. Utilisation against target.
 *    Replaces Excel's bar+line combo. Same measure on one scale, so one
 *    axis — the target is a reference tick, not a second series.
 * ------------------------------------------------------------------ */
export function UtilizationChart({ rows }: { rows: DebtStatus[] }) {
  const [hover, setHover] = useState<number | null>(null)

  const withLimit = rows
    .filter((d) => d.utilization != null && Number(d.credit_limit) > 0)
    .sort((a, b) => Number(b.utilization) - Number(a.utilization))

  if (withLimit.length === 0) {
    return (
      <p className="text-xs text-ink3 px-3 py-4">
        No balances recorded yet, so utilisation can’t be worked out. Open a debt
        below and record a balance.
      </p>
    )
  }

  return (
    <section className="border border-rule mt-4">
      <header className="px-3 pt-3">
        <h3 className="text-[15px]">Balance against target</h3>
        <p className="text-xs text-ink3 mt-0.5">
          How much of each limit is used. The tick is the {pct(Number(withLimit[0].target_utilization ?? 0.3))} target.
        </p>
      </header>

      <ul className="mt-2">
        {withLimit.map((d) => {
          const u = Number(d.utilization)
          const target = Number(d.target_utilization ?? 0.3)
          const over = u > target
          return (
            <li
              key={d.id}
              className={`px-3 py-2 ${hover === d.id ? 'bg-bar' : ''}`}
              onMouseEnter={() => setHover(d.id)}
              onMouseLeave={() => setHover(null)}
            >
              <div className="flex items-baseline justify-between gap-3">
                <span className="text-[13px] truncate min-w-0">{d.name}</span>
                <span className="num text-xs text-ink3 shrink-0">
                  {fmt(d.current_balance)} of {fmt(d.credit_limit)}
                </span>
              </div>

              {/* Track. Target is a tick — a different shape, not a second hue. */}
              <div className="relative mt-1.5 h-2 bg-rule/40">
                <div
                  className={`absolute inset-y-0 left-0 ${over ? 'bg-rust' : 'bg-slate'}`}
                  style={{ width: `${Math.max(0, Math.min(100, u * 100))}%` }}
                />
                <div
                  className="absolute -inset-y-1 w-0.5 bg-ink"
                  style={{ left: `${Math.min(100, target * 100)}%` }}
                  title={`Target ${pct(target)}`}
                />
              </div>

              {/* Over-target never rides on colour alone. */}
              <p className="mt-1 text-[11px]">
                <span className="num">{pct(u)} used</span>
                {over ? (
                  <span className="text-rust"> · {fmt(d.amount_over_target)} over target</span>
                ) : (
                  <span className="text-ink3"> · within target</span>
                )}
                {d.apr != null && (
                  <span className="text-ink3"> · {(Number(d.apr) * 100).toFixed(2)}% APR</span>
                )}
                {hover === d.id && d.balance_as_of && (
                  <span className="text-ink3"> · as of {fmtDate(d.balance_as_of)}</span>
                )}
              </p>
            </li>
          )
        })}
      </ul>

      <p className="eyebrow px-3 py-2 border-t border-rule normal-case tracking-normal">
        <span className="inline-block w-3 h-2 bg-slate align-middle mr-1" /> within target
        <span className="inline-block w-3 h-2 bg-rust align-middle ml-3 mr-1" /> over target
        <span className="inline-block w-0.5 h-3 bg-ink align-middle ml-3 mr-1" /> target
      </p>
    </section>
  )
}

/* ------------------------------------------------------------------ *
 * 2. Where the balance sits.
 *    Excel drew this as an 11-slice pie of per-account percentages, which
 *    don't sum to a whole — so the pie couldn't mean anything. Ranked bars
 *    of each debt's share of the total is the part-to-whole it was after.
 * ------------------------------------------------------------------ */
export function BalanceShareChart({ rows }: { rows: DebtStatus[] }) {
  const [hover, setHover] = useState<number | null>(null)

  const withBalance = rows
    .filter((d) => Number(d.current_balance) > 0)
    .sort((a, b) => Number(b.current_balance) - Number(a.current_balance))

  const total = withBalance.reduce((s, d) => s + Number(d.current_balance), 0)
  if (total === 0) return null

  const largest = Number(withBalance[0].current_balance)

  return (
    <section className="border border-rule mt-4">
      <header className="px-3 pt-3">
        <h3 className="text-[15px]">Where the balance sits</h3>
        <p className="text-xs text-ink3 mt-0.5">
          Each debt’s share of the {fmt(total)} owed, largest first.
        </p>
      </header>

      <ul className="mt-2">
        {withBalance.map((d) => {
          const bal = Number(d.current_balance)
          return (
            <BarRow
              key={d.id}
              label={d.name}
              width={bal / largest}
              hovered={hover === d.id}
              onHover={(on) => setHover(on ? d.id : null)}
              sub={hover === d.id && d.owner_name ? d.owner_name : undefined}
            >
              {fmt(bal)} · {((bal / total) * 100).toFixed(0)}%
            </BarRow>
          )
        })}
      </ul>
    </section>
  )
}
