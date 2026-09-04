import { NavLink, useLocation } from 'react-router-dom'
import type { ReactNode } from 'react'
import { useTheme } from '../hooks/useTheme'

// The list pages read best as one narrow column. The debt page is the only
// one carrying a dashboard beside its list, so it gets the full width.
const WIDE_ROUTES = ['/', '/debts', '/dashboard', '/income']

const tabs = [
  { to: '/', label: 'Budget', end: true },
  { to: '/bills', label: 'Bills' },
  { to: '/income', label: 'Income' },
  { to: '/debts', label: 'Debt' },
  { to: '/dashboard', label: 'Dashboard' },
]

export function Chrome({
  children, who, onSignOut, idleWarning,
}: {
  children: ReactNode
  who: string
  onSignOut: () => void
  /** True in the last couple of minutes before an idle sign-out. */
  idleWarning?: boolean
}) {
  const wide = WIDE_ROUTES.includes(useLocation().pathname)
  const { theme, setTheme } = useTheme()
  return (
    <div className="min-h-dvh flex flex-col">
      <header className="pl-6 pr-4 pt-5 pb-3 flex items-baseline justify-between">
        <h1 className="font-mono text-[13px] tracking-[0.18em] uppercase">Budget Pulse</h1>
        <div className="flex items-center gap-3">
          <label className="flex items-center gap-1.5">
            <span className="eyebrow sr-only">Theme</span>
            <select
              className="border border-rule bg-surface px-1.5 py-0.5 text-[11px]
                         uppercase tracking-[0.14em] text-ink3"
              value={theme}
              onChange={(e) => setTheme(e.target.value as typeof theme)}
              aria-label="Colour theme"
            >
              <option value="system">Auto</option>
              <option value="light">Light</option>
              <option value="dark">Dark</option>
            </select>
          </label>

          <button onClick={onSignOut} className="eyebrow hover:text-ink">
            {who} · sign out
          </button>
        </div>
      </header>

      {idleWarning && (
        <p role="status"
          className="pl-6 pr-4 py-1.5 text-xs text-amber border-t border-amber/40 bg-amber/5">
          Signing out shortly — move the mouse or press a key to stay.
        </p>
      )}

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

      <main className={`flex-1 pl-6 pr-4 pb-16 w-full ${wide ? 'max-w-7xl' : 'max-w-2xl'}`}>
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
