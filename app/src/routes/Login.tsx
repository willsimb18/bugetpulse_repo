import { useState } from 'react'
import { supabase } from '../lib/supabase'

export function Login() {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function signIn() {
    setBusy(true); setErr(null)
    const { error } = await supabase.auth.signInWithPassword({ email, password })
    setBusy(false)
    if (error) setErr(error.message)
  }

  return (
    <div className="min-h-dvh grid place-items-center px-6">
      <div className="w-full max-w-xs">
        <h1 className="font-mono text-[13px] tracking-[0.18em] uppercase mb-1">BudgetPulse</h1>
        <p className="text-sm text-ink3 mb-6">Household budget</p>

        <div className="space-y-3">
          <label className="block">
            <span className="eyebrow block mb-1">Email</span>
            <input
              className="field" type="email" autoComplete="username"
              value={email} onChange={(e) => setEmail(e.target.value)}
              onKeyDown={(e) => e.key === 'Enter' && signIn()}
            />
          </label>
          <label className="block">
            <span className="eyebrow block mb-1">Password</span>
            <input
              className="field" type="password" autoComplete="current-password"
              value={password} onChange={(e) => setPassword(e.target.value)}
              onKeyDown={(e) => e.key === 'Enter' && signIn()}
            />
          </label>

          {err && <p role="alert" className="text-sm text-rust">{err}</p>}

          <button className="btn-go w-full" onClick={signIn} disabled={busy || !email || !password}>
            {busy ? 'Signing in…' : 'Sign in'}
          </button>
        </div>
      </div>
    </div>
  )
}
