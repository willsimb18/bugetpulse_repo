import { useCallback, useEffect, useState } from 'react'

export type Theme = 'light' | 'dark' | 'system'

const KEY = 'bp:theme'

function read(): Theme {
  try {
    const v = localStorage.getItem(KEY)
    return v === 'light' || v === 'dark' ? v : 'system'
  } catch {
    // Private windows and blocked site data throw on access. Following the
    // system is the right thing to fall back to.
    return 'system'
  }
}

/*
 * Light, dark, or whatever the machine is set to.
 *
 * "system" writes no attribute at all, which is what lets the
 * prefers-color-scheme block in index.css take over. An explicit choice
 * stamps data-theme and wins in both directions — including choosing
 * light on a machine set to dark.
 */
export function useTheme() {
  const [theme, setThemeState] = useState<Theme>(read)

  useEffect(() => {
    const root = document.documentElement
    if (theme === 'system') root.removeAttribute('data-theme')
    else root.setAttribute('data-theme', theme)

    // Keep the browser/PWA chrome in step with the page.
    const meta = document.querySelector('meta[name="theme-color"]')
    if (meta) {
      const bg = getComputedStyle(root).getPropertyValue('--paper').trim()
      if (bg) meta.setAttribute('content', `rgb(${bg})`)
    }
  }, [theme])

  // On "system", re-run the effect when the machine flips so the
  // theme-color meta follows too.
  useEffect(() => {
    if (theme !== 'system') return
    const mq = window.matchMedia('(prefers-color-scheme: dark)')
    const onChange = () => setThemeState('system')
    mq.addEventListener('change', onChange)
    return () => mq.removeEventListener('change', onChange)
  }, [theme])

  const setTheme = useCallback((next: Theme) => {
    setThemeState(next)
    try {
      if (next === 'system') localStorage.removeItem(KEY)
      else localStorage.setItem(KEY, next)
    } catch { /* see read() */ }
  }, [])

  return { theme, setTheme }
}
