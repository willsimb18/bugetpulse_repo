import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { useAuth } from './hooks/useAuth'
import { Chrome } from './components/Chrome'
import { Login } from './routes/Login'
import { Period } from './routes/Period'
import { Money } from './routes/Money'
import { Bills } from './routes/Bills'
import { Income } from './routes/Income'
import { Debts } from './routes/Debts'

export default function App() {
  const { session, profile, loading, isOwner, signOut } = useAuth()

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
      <Chrome who={profile.display_name} onSignOut={signOut}>
        <Routes>
          <Route path="/" element={<Period isOwner={isOwner} />} />
          <Route path="/money" element={<Money />} />
          <Route path="/bills" element={<Bills isOwner={isOwner} />} />
          <Route path="/income" element={<Income isOwner={isOwner} />} />
          <Route path="/debts" element={<Debts isOwner={isOwner} />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </Chrome>
    </BrowserRouter>
  )
}
