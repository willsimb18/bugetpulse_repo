import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { useCallback } from 'react'
import { useAuth } from './hooks/useAuth'
import { clearIdleClock, useIdleSignOut } from './hooks/useIdleSignOut'
import { Chrome } from './components/Chrome'
import { Login } from './routes/Login'
import { Period } from './routes/Period'
import { Dashboard } from './routes/Dashboard'
import { Bills } from './routes/Bills'
import { Income } from './routes/Income'
import { Debts } from './routes/Debts'

// An hour of nothing signs you out. Household finances on a machine
// someone else may sit down at.
const IDLE_MINUTES = 60

export default function App() {
  const { session, profile, loading, isOwner, signOut } = useAuth()

  const endSession = useCallback(() => {
    clearIdleClock()
    void signOut()
  }, [signOut])

  const idleWarning = useIdleSignOut(!!session, IDLE_MINUTES, endSession)

  if (loading) {
    return <div className="min-h-dvh grid place-items-center text-sm text-ink3">Loading…</div>
  }
  if (!session) return <Login />
  if (!profile) {
    return (
      <div className="min-h-dvh grid place-items-center px-6 text-center">
        <div>
          <p className="text-sm mb-3">
            This account isn’t linked to a household yet. An owner needs to add a profile row for it.
          </p>
          <button className="btn" onClick={signOut}>Sign out</button>
        </div>
      </div>
    )
  }

  return (
    <BrowserRouter>
      <Chrome who={profile.display_name} onSignOut={endSession} idleWarning={idleWarning}>
        <Routes>
          <Route path="/" element={<Period isOwner={isOwner} />} />
          <Route path="/bills" element={<Bills isOwner={isOwner} />} />
          <Route path="/income" element={<Income isOwner={isOwner} />} />
          <Route path="/debts" element={<Debts isOwner={isOwner} />} />
          <Route path="/dashboard" element={<Dashboard />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </Chrome>
    </BrowserRouter>
  )
}
