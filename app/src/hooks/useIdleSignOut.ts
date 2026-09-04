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
const WRITE_EVERY_MS = 60_000
const CHECK_EVERY_MS = 30_000

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

  useEffect(() => {
    if (!enabled) { setWarning(false); return }

    const limit = minutes * 60_000
    fired.current = false
    write(Date.now())

    const touch = () => {
      const now = Date.now()
      setWarning(false)
      if (now - lastWrite.current < WRITE_EVERY_MS) return
      lastWrite.current = now
      write(now)
    }

    const check = () => {
      if (fired.current) return
      const idle = Date.now() - read()
      // Warn in the last two minutes, so a half-typed amount isn't lost
      // without notice.
      setWarning(idle > limit - 120_000 && idle < limit)
      if (idle >= limit) {
        fired.current = true
        setWarning(false)
        clearIdleClock()
        onIdle()
      }
    }

    for (const e of EVENTS) window.addEventListener(e, touch, { passive: true })
    // Coming back to the tab is the moment a long absence shows up.
    document.addEventListener('visibilitychange', check)
    const id = window.setInterval(check, CHECK_EVERY_MS)
    check()

    return () => {
      for (const e of EVENTS) window.removeEventListener(e, touch)
      document.removeEventListener('visibilitychange', check)
      window.clearInterval(id)
    }
  }, [enabled, minutes, onIdle])

  return warning
}
