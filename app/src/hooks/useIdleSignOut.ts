import { useEffect, useRef, useState } from 'react'

/*
 * Sign out after a stretch of doing nothing.
 *
 * The last-active time is kept in localStorage rather than in a variable,
 * so closing the window counts as idle. A PWA left in the Dock and
 * reopened the next morning should ask for a password, and an in-memory
 * timer would have been reset to zero by the reload.
 *
 * Activity is throttled to one write a minute — a mousemove listener that
 * touched localStorage on every event would be pointless work for a value
 * that only matters to the minute.
 */
const KEY = 'bp:last-active'

/*
 * Both of these scale with the timeout. At the hour they are a minute and
 * thirty seconds — cheap. At the half minute used for testing they become
 * three and five seconds, because a throttle longer than the timeout would
 * mean moving the mouse failed to reset the clock, and a check interval
 * longer than it would mean signing out at some arbitrary point after the
 * limit rather than at it.
 */
const writeEvery = (limit: number) => Math.min(60_000, Math.max(1_000, limit / 10))
const checkEvery = (limit: number) => Math.min(30_000, Math.max(1_000, limit / 6))

const EVENTS = [
  'mousedown', 'keydown', 'wheel', 'touchstart', 'pointerdown', 'scroll',
] as const

function read(): number {
  try {
    const v = Number(localStorage.getItem(KEY))
    return Number.isFinite(v) && v > 0 ? v : Date.now()
  } catch {
    // Private windows and blocked site data throw on access. Treat it as
    // "active now" so a storage failure can never sign someone out.
    return Date.now()
  }
}

function write(t: number) {
  try { localStorage.setItem(KEY, String(t)) } catch { /* see read() */ }
}

export function clearIdleClock() {
  try { localStorage.removeItem(KEY) } catch { /* ignore */ }
}

export function useIdleSignOut(
  enabled: boolean,
  minutes: number,
  onIdle: () => void,
) {
  const [warning, setWarning] = useState(false)
  const lastWrite = useRef(0)
  const fired = useRef(false)

  // onIdle is held in a ref, and deliberately NOT an effect dependency.
  // A caller passing a fresh closure each render -- which is the normal
  // thing to do -- would otherwise restart the effect on every render,
  // and the effect resets the clock. Showing the warning re-renders, so
  // the timer reset itself the moment it was about to fire and could
  // never reach the limit.
  const onIdleRef = useRef(onIdle)
  useEffect(() => { onIdleRef.current = onIdle }, [onIdle])

  useEffect(() => {
    if (!enabled) { setWarning(false); return }

    const limit = minutes * 60_000
    fired.current = false
    write(Date.now())

    const touch = () => {
      const now = Date.now()
      setWarning(false)
      if (now - lastWrite.current < writeEvery(limit)) return
      lastWrite.current = now
      write(now)
    }

    const check = () => {
      if (fired.current) return
      const idle = Date.now() - read()
      // Warn for the last stretch, so a half-typed amount isn't lost
      // without notice. Two minutes normally, but proportional on a short
      // timeout — a 30-second test would otherwise warn from the start.
      const warnFor = Math.min(120_000, limit * 0.2)
      setWarning(idle > limit - warnFor && idle < limit)
      if (idle >= limit) {
        fired.current = true
        setWarning(false)
        clearIdleClock()
        onIdleRef.current()
      }
    }

    for (const e of EVENTS) window.addEventListener(e, touch, { passive: true })
    // Coming back to the tab is the moment a long absence shows up.
    document.addEventListener('visibilitychange', check)
    const id = window.setInterval(check, checkEvery(limit))
    check()

    return () => {
      for (const e of EVENTS) window.removeEventListener(e, touch)
      document.removeEventListener('visibilitychange', check)
      window.clearInterval(id)
    }
  }, [enabled, minutes])

  return warning
}
