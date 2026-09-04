/** @type {import('tailwindcss').Config} */

// Every colour is a CSS variable holding RGB channels, so a theme swap is
// a variable change rather than a rebuild. The <alpha-value> placeholder
// is what keeps bg-rust/5 and border-amber/40 working.
const themed = (name) => `rgb(var(--${name}) / <alpha-value>)`

export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        ink:     themed('ink'),
        ink2:    themed('ink2'),
        ink3:    themed('ink3'),
        paper:   themed('paper'),
        surface: themed('surface'),
        bar:     themed('bar'),
        rule:    themed('rule'),
        rust:    themed('rust'),
        moss:    themed('moss'),
        teal:    themed('teal'),
        amber:   themed('amber'),
        slate:   themed('slate'),
      },
      fontFamily: {
        sans: ['"IBM Plex Sans"', 'system-ui', 'sans-serif'],
        mono: ['"IBM Plex Mono"', 'ui-monospace', 'monospace'],
      },
      borderRadius: { DEFAULT: '3px', md: '4px' },
    },
  },
  plugins: [],
}
