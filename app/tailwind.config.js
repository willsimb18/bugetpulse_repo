/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        ink:    '#16241F',
        ink2:   '#3D504A',
        ink3:   '#6E827B',
        paper:  '#FBFCFA',
        bar:    '#E7F0E7',
        rule:   '#CBD8CB',
        rust:   '#B4451F',
        moss:   '#2F6B4F',
        amber:  '#A9720E',
        slate:  '#31556E',
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
