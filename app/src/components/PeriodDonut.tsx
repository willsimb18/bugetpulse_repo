import { useMemo, useState } from 'react'
import { fmt, fmtShort } from '../lib/format'
import { BAD, GOOD, SERIES } from '../lib/chart'
import type { BudgetLine, PeriodSummary } from '../lib/types'

/*
 * Where this period's money is spoken for.
 *
 * The ring is the period's income, and each segment is a category's claim
 * on it. What is left unfilled is what has not been allocated — so a
 * glance says both "what am I spending on" and "is any of it left", which
 * two separate charts would have said less well.
 *
 * Only four categories get a colour. SERIES holds four validated hues and
 * a fifth would have to be invented, so everything past the top four
 * folds into Other — which is also roughly where a ring stops being
 * readable. The legend still lists every one of them by name.
 *
 * Over-allocated periods fill the ring completely and report the
 * shortfall in words rather than drawing an arc longer than the circle.
 */
const SLICES = 4
const R = 68
const C = 2 * Math.PI * R

interface Part { name: string; amount: number; color: string }

export function PeriodDonut({ lines, summary }: {
  lines: BudgetLine[]
  summary: PeriodSummary | null
}) {
  const [hover, setHover] = useState<string | null>(null)

  const income = Number(summary?.net_income ?? 0)
  const wages = Number(summary?.wage_income ?? 0)
  const movedIn = Math.max(0, income - wages)

  const parts = useMemo<Part[]>(() => {
    const by = new Map<string, number>()
    for (const l of lines) {
      const key = l.type_name ?? 'Uncategorised'
      by.set(key, (by.get(key) ?? 0) + Number(l.amount_due ?? 0))
    }
    const ranked = [...by.entries()]
      .filter(([, v]) => v > 0)
      .sort((a, b) => b[1] - a[1])

    const top = ranked.slice(0, SLICES).map(([name, amount], i) => ({
      name, amount, color: SERIES[i],
    }))
    const rest = ranked.slice(SLICES).reduce((t, [, v]) => t + v, 0)
    return rest > 0
      ? [...top, { name: `Other (${ranked.length - SLICES})`, amount: rest,
                   color: 'rgb(var(--ink3))' }]
      : top
  }, [lines])

  const allocated = parts.reduce((t, p) => t + p.amount, 0)
  if (allocated === 0 && income === 0) return null

  // The ring is scaled to income while there is any, so the gap reads as
  // headroom. Once allocation passes income the ring is full and the
  // scale becomes the allocation itself.
  const scale = Math.max(income, allocated) || 1
  const leftOver = income - allocated

  let cursor = 0
  const arcs = parts.map((p) => {
    const len = (p.amount / scale) * C
    const arc = { ...p, len, offset: -cursor }
    cursor += len
    return arc
  })

  return (
    <section className="border border-rule">
      <header className="px-3 pt-3">
        <h3 className="text-[15px]">Where this period is spoken for</h3>
        <p className="text-xs text-ink3 mt-0.5">
          Every bill and expense due, grouped by category, against what came in.
        </p>
      </header>

      <div className="p-3 flex flex-wrap items-center justify-center gap-x-6 gap-y-4">
        <div className="relative shrink-0">
          <svg width="172" height="172" viewBox="0 0 172 172" role="img"
            aria-label={`${fmt(allocated)} allocated of ${fmt(income)} income`}>
            <g transform="translate(86,86) rotate(-90)">
              <circle r={R} fill="none" strokeWidth="20"
                stroke="rgb(var(--rule) / 0.45)" />
              {arcs.map((a) => (
                <circle key={a.name} r={R} fill="none" strokeWidth="20"
                  stroke={a.color}
                  strokeDasharray={`${Math.max(0, a.len - 2)} ${C}`}
                  strokeDashoffset={a.offset}
                  opacity={hover && hover !== a.name ? 0.35 : 1}
                  onMouseEnter={() => setHover(a.name)}
                  onMouseLeave={() => setHover(null)}
                >
                  <title>{`${a.name} — ${fmt(a.amount)}`}</title>
                </circle>
              ))}
            </g>
          </svg>

          {/* The number people actually came for, in the hole. */}
          <div className="absolute inset-0 grid place-items-center pointer-events-none">
            <div className="text-center">
              <p className="num text-[21px] leading-none">{fmtShort(income)}</p>
              <p className="eyebrow mt-1">came in</p>
            </div>
          </div>
        </div>

        <dl className="flex-1 min-w-[14rem] text-[13px]">
          {parts.map((p) => (
            <div key={p.name}
              className={`flex items-baseline justify-between gap-3 py-0.5 ${
                hover === p.name ? 'bg-bar' : ''}`}
              onMouseEnter={() => setHover(p.name)}
              onMouseLeave={() => setHover(null)}
            >
              <dt className="min-w-0 truncate">
                <span className="inline-block w-2.5 h-2.5 align-[-1px] mr-2"
                  style={{ backgroundColor: p.color }} />
                {p.name}
              </dt>
              <dd className="num shrink-0">{fmt(p.amount)}</dd>
            </div>
          ))}

          <div className="flex items-baseline justify-between gap-3 py-1 mt-1
                          border-t border-rule">
            <dt className="text-ink3">
              {leftOver >= 0 ? 'Not yet allocated' : 'Short by'}
            </dt>
            <dd className="num" style={{ color: leftOver >= 0 ? GOOD : BAD }}>
              {fmt(Math.abs(leftOver))}
            </dd>
          </div>

          <p className="eyebrow mt-2 normal-case tracking-normal">
            {fmtShort(wages)} pay
            {movedIn > 0 && ` · ${fmtShort(movedIn)} moved in`}
            {` · ${fmtShort(allocated)} due`}
          </p>
        </dl>
      </div>
    </section>
  )
}
