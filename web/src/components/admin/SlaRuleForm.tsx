import { useState } from 'react'
import type { Database } from '../../lib/database.types'
import { CONFIDENCE_LABEL, PLAYBOOK_ACTION_TYPE_LABEL, SOURCE_CATEGORY_LABEL } from '../../lib/incidentRules'
import { createSlaRule, updateSlaRule, type SlaRuleFormFields, type SlaRuleRow } from '../../lib/ops'
import { FormActions, NumberField, SelectField, TextField } from './formFields'

type SourceCategory = Database['public']['Enums']['source_category']
type SourceConfidenceLevel = Database['public']['Enums']['source_confidence_level']

const SEVERITY_OPTIONS = [
  { value: 'low', label: 'Low' },
  { value: 'moderate', label: 'Moderate' },
  { value: 'high', label: 'High' },
  { value: 'severe', label: 'Severe' },
]

const TIME_OF_DAY_OPTIONS = [
  { value: 'business_hours', label: 'Business hours' },
  { value: 'after_hours', label: 'After hours' },
]

const SOURCE_CATEGORY_OPTIONS = (Object.entries(SOURCE_CATEGORY_LABEL) as [SourceCategory, string][]).map(
  ([value, label]) => ({ value, label }),
)
const EVIDENCE_LEVEL_OPTIONS = (Object.entries(CONFIDENCE_LABEL) as [SourceConfidenceLevel, string][]).map(
  ([value, label]) => ({ value, label }),
)
const ACTION_TYPE_OPTIONS = Object.entries(PLAYBOOK_ACTION_TYPE_LABEL).map(([value, label]) => ({ value, label }))

function toFields(row: SlaRuleRow | null): SlaRuleFormFields {
  return {
    slug: row?.slug ?? null,
    severity: row?.severity ?? null,
    source_category: row?.source_category ?? null,
    evidence_level: row?.evidence_level ?? null,
    action_type: row?.action_type ?? null,
    agency: row?.agency ?? null,
    time_of_day: row?.time_of_day ?? null,
    ack_hours: row?.ack_hours ?? 2,
    accept_hours: row?.accept_hours ?? 4,
    arrival_hours: row?.arrival_hours ?? 8,
    completion_hours: row?.completion_hours ?? 24,
    verification_hours: row?.verification_hours ?? 72,
    priority: row?.priority ?? 0,
  }
}

export default function SlaRuleForm({
  cityId,
  existing,
  onSaved,
  onCancel,
}: {
  cityId: number
  existing: SlaRuleRow | null
  onSaved: () => void
  onCancel: () => void
}) {
  const [fields, setFields] = useState<SlaRuleFormFields>(() => toFields(existing))
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const set = <K extends keyof SlaRuleFormFields>(key: K, value: SlaRuleFormFields[K]) =>
    setFields((f) => ({ ...f, [key]: value }))

  // Hours are checked roughly increasing — warned, not blocked, since a city
  // may legitimately have a non-monotonic policy (e.g. a fast-arrival,
  // slow-verification rule).
  const hoursOutOfOrder =
    fields.ack_hours > fields.accept_hours ||
    fields.accept_hours > fields.arrival_hours ||
    fields.arrival_hours > fields.completion_hours ||
    fields.completion_hours > fields.verification_hours

  const submit = async (e: React.FormEvent) => {
    e.preventDefault()
    setBusy(true)
    setError(null)
    try {
      if (existing) {
        await updateSlaRule(existing.id, fields)
      } else {
        await createSlaRule(cityId, fields)
      }
      onSaved()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not save the SLA rule')
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={submit} className="space-y-3">
      <TextField label="Slug (optional, stable id)" value={fields.slug ?? ''} onChange={(v) => set('slug', v || null)} />
      <div className="grid grid-cols-2 gap-3">
        <SelectField
          label="Severity"
          value={fields.severity ?? ''}
          onChange={(v) => set('severity', v || null)}
          options={SEVERITY_OPTIONS}
          allowEmpty
        />
        <SelectField
          label="Time of day"
          value={fields.time_of_day ?? ''}
          onChange={(v) => set('time_of_day', v || null)}
          options={TIME_OF_DAY_OPTIONS}
          allowEmpty
        />
        <SelectField
          label="Source category"
          value={fields.source_category ?? ''}
          onChange={(v) => set('source_category', v || null)}
          options={SOURCE_CATEGORY_OPTIONS}
          allowEmpty
        />
        <SelectField
          label="Evidence level"
          value={fields.evidence_level ?? ''}
          onChange={(v) => set('evidence_level', v || null)}
          options={EVIDENCE_LEVEL_OPTIONS}
          allowEmpty
        />
        <SelectField
          label="Action type"
          value={fields.action_type ?? ''}
          onChange={(v) => set('action_type', v || null)}
          options={ACTION_TYPE_OPTIONS}
          allowEmpty
        />
        <TextField label="Agency" value={fields.agency ?? ''} onChange={(v) => set('agency', v || null)} />
      </div>

      <p className="pt-1 text-xs font-semibold uppercase tracking-wide text-slate-400">SLA checkpoints (hours)</p>
      <div className="grid grid-cols-3 gap-3">
        <NumberField label="Ack" value={fields.ack_hours} onChange={(v) => set('ack_hours', v ?? 0)} min={0} step={0.5} />
        <NumberField
          label="Accept"
          value={fields.accept_hours}
          onChange={(v) => set('accept_hours', v ?? 0)}
          min={0}
          step={0.5}
        />
        <NumberField
          label="Arrival"
          value={fields.arrival_hours}
          onChange={(v) => set('arrival_hours', v ?? 0)}
          min={0}
          step={0.5}
        />
        <NumberField
          label="Completion"
          value={fields.completion_hours}
          onChange={(v) => set('completion_hours', v ?? 0)}
          min={0}
          step={0.5}
        />
        <NumberField
          label="Verification"
          value={fields.verification_hours}
          onChange={(v) => set('verification_hours', v ?? 0)}
          min={0}
          step={0.5}
        />
        <NumberField label="Priority" value={fields.priority} onChange={(v) => set('priority', v ?? 0)} min={0} />
      </div>
      {hoursOutOfOrder && (
        <p className="rounded-lg bg-status-warning/10 px-3 py-2 text-xs text-status-warning">
          Checkpoints aren't in ack ≤ accept ≤ arrival ≤ completion ≤ verification order. That's allowed if this city's
          policy really is non-monotonic — just confirm it's intentional.
        </p>
      )}

      <FormActions onCancel={onCancel} submitLabel={existing ? 'Save changes' : 'Create rule'} busy={busy} error={error} />
    </form>
  )
}
