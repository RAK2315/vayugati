import { RadioTower } from 'lucide-react'

export default function EmptySensorState({ filtered = false }: { filtered?: boolean }) {
  return (
    <div className="flex flex-col items-center justify-center gap-2 px-4 py-14 text-center">
      <RadioTower className="h-6 w-6 text-slate-300" strokeWidth={1.75} aria-hidden />
      <p className="max-w-sm text-sm text-slate-500">
        {filtered
          ? 'No stations match this filter.'
          : 'No CAAQMS stations are configured yet. This page monitors station freshness and reliability once stations exist.'}
      </p>
    </div>
  )
}
