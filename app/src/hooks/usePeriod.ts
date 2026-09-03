import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { BudgetLine, BudgetPeriod, Funding, PeriodSummary } from '../lib/types'

export function usePeriods() {
  const [periods, setPeriods] = useState<BudgetPeriod[]>([])
  const [index, setIndex] = useState(0)

  useEffect(() => {
    supabase
      .from('budget_period')
      .select('id, period_start, period_end, pay_date, label, is_closed, opening_balance')
      .order('period_start', { ascending: true })
      .then(({ data }) => {
        const rows = (data ?? []) as BudgetPeriod[]
        setPeriods(rows)
        const today = new Date().toISOString().slice(0, 10)
        const i = rows.findIndex((p) => p.period_start <= today && today <= p.period_end)
        setIndex(i >= 0 ? i : Math.max(0, rows.length - 1))
      })
  }, [])

  return {
    periods,
    current: periods[index] ?? null,
    index,
    hasPrev: index > 0,
    hasNext: index < periods.length - 1,
    prev: () => setIndex((i) => Math.max(0, i - 1)),
    next: () => setIndex((i) => Math.min(periods.length - 1, i + 1)),
  }
}

export function usePeriodDetail(periodId: number | null) {
  const [summary, setSummary] = useState<PeriodSummary | null>(null)
  const [lines, setLines] = useState<BudgetLine[]>([])
  const [funding, setFunding] = useState<Funding[]>([])
  const [loading, setLoading] = useState(true)

  const load = useCallback(async () => {
    if (!periodId) return
    const [s, l, f] = await Promise.all([
      supabase.from('v_period_summary').select('*').eq('budget_period_id', periodId).single(),
      supabase.from('v_budget_line_detail').select('*').eq('budget_period_id', periodId)
        .order('due_date', { ascending: true }).order('name', { ascending: true }),
      supabase.from('v_period_funding').select('*').eq('budget_period_id', periodId)
        .order('received_on', { ascending: true }),
    ])
    setSummary(s.data as PeriodSummary | null)
    setLines((l.data ?? []) as BudgetLine[])
    setFunding((f.data ?? []) as Funding[])
    setLoading(false)
  }, [periodId])

  useEffect(() => { setLoading(true); void load() }, [load])

  // When one of you marks something paid, the other's screen follows.
  useEffect(() => {
    if (!periodId) return
    const ch = supabase
      .channel(`lines-${periodId}`)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'budget_line', filter: `budget_period_id=eq.${periodId}` },
        () => { void load() },
      )
      .subscribe()
    return () => { void supabase.removeChannel(ch) }
  }, [periodId, load])

  return { summary, lines, funding, loading, reload: load }
}
