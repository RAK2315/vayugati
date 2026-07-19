/**
 * Small shared field primitives for the registry/SLA-rule/playbook editor
 * forms (Phase 12) — not a form library, just the handful of labeled-input
 * shapes those three forms all need, kept in one place so they render
 * identically rather than being copy-pasted three times.
 */
import type { ReactNode } from 'react'

function FieldWrap({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className="block text-xs font-medium text-slate-500">
      <span className="mb-1 block">{label}</span>
      {children}
    </label>
  )
}

const inputClass =
  'focus-ring w-full rounded-lg border border-slate-200 px-2.5 py-1.5 text-sm text-slate-800'

export function TextField({
  label,
  value,
  onChange,
  required,
  placeholder,
}: {
  label: string
  value: string
  onChange: (v: string) => void
  required?: boolean
  placeholder?: string
}) {
  return (
    <FieldWrap label={label}>
      <input
        type="text"
        value={value}
        required={required}
        placeholder={placeholder}
        onChange={(e) => onChange(e.target.value)}
        className={inputClass}
      />
    </FieldWrap>
  )
}

export function TextAreaField({
  label,
  value,
  onChange,
  rows = 3,
}: {
  label: string
  value: string
  onChange: (v: string) => void
  rows?: number
}) {
  return (
    <FieldWrap label={label}>
      <textarea value={value} rows={rows} onChange={(e) => onChange(e.target.value)} className={inputClass} />
    </FieldWrap>
  )
}

export function NumberField({
  label,
  value,
  onChange,
  min,
  step,
}: {
  label: string
  value: number | null
  onChange: (v: number | null) => void
  min?: number
  step?: number
}) {
  return (
    <FieldWrap label={label}>
      <input
        type="number"
        value={value ?? ''}
        min={min}
        step={step ?? 1}
        onChange={(e) => onChange(e.target.value === '' ? null : Number(e.target.value))}
        className={inputClass}
      />
    </FieldWrap>
  )
}

export function SelectField<T extends string>({
  label,
  value,
  onChange,
  options,
  allowEmpty,
}: {
  label: string
  value: T
  onChange: (v: T) => void
  options: { value: T; label: string }[]
  /** Adds a leading "-" option that maps to '' — for nullable enum columns. */
  allowEmpty?: boolean
}) {
  return (
    <FieldWrap label={label}>
      <select value={value} onChange={(e) => onChange(e.target.value as T)} className={inputClass}>
        {allowEmpty && <option value="">-</option>}
        {options.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
    </FieldWrap>
  )
}

export function CheckboxField({
  label,
  checked,
  onChange,
}: {
  label: string
  checked: boolean
  onChange: (v: boolean) => void
}) {
  return (
    <label className="flex items-center gap-2 text-sm text-slate-700">
      <input
        type="checkbox"
        checked={checked}
        onChange={(e) => onChange(e.target.checked)}
        className="focus-ring h-4 w-4 rounded border-slate-300"
      />
      {label}
    </label>
  )
}

export function FormActions({
  onCancel,
  submitLabel,
  busy,
  error,
}: {
  onCancel: () => void
  submitLabel: string
  busy: boolean
  error: string | null
}) {
  return (
    <div className="mt-4 space-y-2">
      {error && <p className="rounded-lg bg-status-critical/10 px-3 py-2 text-xs text-status-critical">{error}</p>}
      <div className="flex justify-end gap-2">
        <button
          type="button"
          onClick={onCancel}
          className="focus-ring rounded-lg border border-slate-200 px-3 py-1.5 text-xs font-semibold text-slate-600 hover:bg-slate-50"
        >
          Cancel
        </button>
        <button
          type="submit"
          disabled={busy}
          className="focus-ring rounded-lg bg-ink-700 px-3 py-1.5 text-xs font-semibold text-white hover:bg-ink-800 disabled:opacity-50"
        >
          {busy ? 'Saving…' : submitLabel}
        </button>
      </div>
    </div>
  )
}
