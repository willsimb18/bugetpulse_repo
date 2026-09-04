import { useCallback, useEffect, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase } from '../lib/supabase'
import type { Profile } from '../lib/types'

export function useAuth() {
  const [session, setSession] = useState<Session | null>(null)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session)
      if (!data.session) setLoading(false)
    })
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => {
      setSession(s)
      if (!s) { setProfile(null); setLoading(false) }
    })
    return () => sub.subscription.unsubscribe()
  }, [])

  useEffect(() => {
    if (!session) return
    let cancelled = false
    supabase
      .from('profile')
      .select('id, household_id, display_name, role')
      .eq('id', session.user.id)
      .single()
      .then(({ data }) => {
        if (cancelled) return
        setProfile(data as Profile | null)
        setLoading(false)
      })
    return () => { cancelled = true }
  }, [session])

  // Stable identity: this ends up in effect dependencies, and a fresh
  // closure each render restarts whatever depends on it.
  const signOut = useCallback(() => { void supabase.auth.signOut() }, [])

  return {
    session,
    profile,
    loading,
    isOwner: profile?.role === 'owner',
    signOut,
  }
}
