import { NavLink, useLocation } from 'react-router-dom'
import type { ReactNode } from 'react'

// The list pages read best as one narrow column. The debt page is the only
// one carrying a dashboard beside its list, so it gets the full width.
const WIDE_ROUTES = ['/debts']

const tabs = [
  { to: '/', label: 'Budget', end: true },
  { to: '/bills', label: 'Bills' },
  { to: '/income', label: 'Income' },
  { to: '/debts', label: 'Debt' },
]

export function Chrome({
  children, who, onSignOut,
}: { children: ReactNode; who: string; onSignOut: () => void }) {
  const wide = WIDE_ROUTES.includes(useLocation().pathname)
  return (
    <div className="min-h-dvh flex flex-col">
      <header className="pl-6 pr-4 pt-5 pb-3 flex items-baseline justify-between">
        <h1 className="font-mono text-[13px] tracking-[0.18em] uppercase">BudgetPulse</h1>
        <button onClick={onSignOut} className="eyebrow hover:text-ink">
          {who} · sign out
        </button>
      </header>

      <nav className="pl-6 pr-4 flex gap-5 rule-t border-b border-rule">
        {tabs.map((t) => (
          <NavLink
            key={t.to}
            to={t.to}
            end={t.end}
            className={({ isActive }) =>
              `py-2.5 text-sm border-b-2 -mb-px ${
                isActive ? 'border-ink text-ink font-medium' : 'border-transparent text-ink3'
              }`
            }
          >
            {t.label}
          </NavLink>
        ))}
      </nav>

      <main className={`flex-1 pl-6 pr-4 pb-16 w-full ${wide ? 'max-w-6xl' : 'max-w-2xl'}`}>
        {children}
      </main>
    </div>
  )
}

export function Empty({ children }: { children: ReactNode }) {
  return <p className="py-10 text-sm text-ink3">{children}</p>
}

export function Err({ msg }: { msg: string | null }) {
  if (!msg) return null
  return (
    <p role="alert" className="my-3 px-3 py-2 border border-rust/40 bg-rust/5 text-sm text-rust">
      {msg}
    </p>
  )
}
