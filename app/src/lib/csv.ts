/*
 * CSV export.
 *
 * Money goes out as bare numbers — 2290.82, not $2,290.82 — because the
 * point of exporting is to sum it somewhere else, and a currency symbol
 * or a thousands separator turns the column into text that Excel will not
 * add up. Dates go out ISO for the same reason: yyyy-mm-dd sorts
 * correctly as text, where "Sep 1" does not.
 */

/** RFC 4180: quote if it contains a comma, quote or newline; "" escapes a quote. */
function cell(v: unknown): string {
  if (v == null) return ''
  const s = String(v)
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s
}

export function toCsv(headers: string[], rows: unknown[][]): string {
  return [headers, ...rows].map((r) => r.map(cell).join(',')).join('\r\n')
}

export function downloadCsv(filename: string, csv: string) {
  // The BOM is what makes Excel read it as UTF-8 rather than mangling any
  // non-ASCII in an account name.
  const blob = new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8;' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  a.remove()
  // Revoked on the next tick — revoking synchronously can cancel the
  // download in some browsers before it has started reading the blob.
  setTimeout(() => URL.revokeObjectURL(url), 0)
}
