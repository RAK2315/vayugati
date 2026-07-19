import { useState } from 'react'
import type { Database } from '../../lib/database.types'
import {
  CONFIDENCE_LABEL,
  PLAYBOOK_ACTION_TYPE_LABEL,
  SOURCE_CATEGORY_LABEL,
  type ChecklistItem,
} from '../../lib/incidentRules'
import { createPlaybook, updatePlaybook, type PlaybookFormFields, type PlaybookRow } from '../../lib/ops'
import { CheckboxField, FormActions, NumberField, SelectField, TextAreaField, TextField } from './formFields'

type SourceCategory = Database['public']['Enums']['source_category']
type SourceConfidenceLevel = Database['public']['Enums']['source_confidence_level']
type ApprovalLevel = Database['public']['Enums']['approval_level']

const SOURCE_CATEGORY_OPTIONS = (Object.entries(SOURCE_CATEGORY_LABEL) as [SourceCategory, string][]).map(
  ([value, label]) => ({ value, label }),
)
const ACTION_TYPE_OPTIONS = Object.entries(PLAYBOOK_ACTION_TYPE_LABEL).map(([value, label]) => ({ value, label }))
const EVIDENCE_LEVEL_OPTIONS = (Object.entries(CONFIDENCE_LABEL) as [SourceConfidenceLevel, string][]).map(
  ([value, label]) => ({ value, label }),
)
const APPROVAL_LEVEL_OPTIONS: { value: ApprovalLevel; label: string }[] = [
  { value: 'automatic', label: 'Automatic' },
  { value: 'command', label: 'Command' },
  { value: 'authorised_legal', label: 'Authorised (legal)' },
]
const EVIDENCE_BASIS_OPTIONS = [
  { value: 'literature', label: 'Literature' },
  { value: 'expert_estimate', label: 'Expert estimate' },
  { value: 'vayu_gati_observation', label: 'Vayu Gati observation' },
]
const POLLUTANT_OPTIONS = ['pm25', 'pm10', 'no2', 'so2', 'co', 'o3']

function toFields(row: PlaybookRow | null): PlaybookFormFields {
  return {
    title: row?.title ?? '',
    source_category: row?.source_category ?? null,
    action_type: row?.action_type ?? 'inspect',
    min_evidence_level: row?.min_evidence_level ?? 'corroborated',
    approval_level: row?.approval_level ?? 'command',
    for_regional: row?.for_regional ?? false,
    checklist: (row?.checklist as ChecklistItem[] | null) ?? [],
    required_team: row?.required_team ?? null,
    required_equipment: row?.required_equipment ?? null,
    estimated_minutes: row?.estimated_minutes ?? null,
    estimated_cost_min: row?.estimated_cost_min ?? null,
    estimated_cost_max: row?.estimated_cost_max ?? null,
    expected_effect: row?.expected_effect ?? null,
    expected_time_to_effect_hours: row?.expected_time_to_effect_hours ?? null,
    expected_duration_hours: row?.expected_duration_hours ?? null,
    verification_window_hours: row?.verification_window_hours ?? null,
    known_limitations: row?.known_limitations ?? null,
    required_proof: row?.required_proof ?? null,
    verification_method: row?.verification_method ?? null,
    evidence_basis: row?.evidence_basis ?? null,
    responsible_agency_type: row?.responsible_agency_type ?? null,
    instructions: row?.instructions ?? null,
    recommended_pollutants: row?.recommended_pollutants ?? [],
    slug: row?.slug ?? null,
    version: row?.version ?? 1,
  }
}

export default function PlaybookForm({
  cityId,
  existing,
  onSaved,
  onCancel,
}: {
  cityId: number
  existing: PlaybookRow | null
  onSaved: () => void
  onCancel: () => void
}) {
  const [fields, setFields] = useState<PlaybookFormFields>(() => toFields(existing))
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const set = <K extends keyof PlaybookFormFields>(key: K, value: PlaybookFormFields[K]) =>
    setFields((f) => ({ ...f, [key]: value }))

  // DB check: not for_regional or source_category is null — a regional
  // playbook cannot also claim a specific local source.
  const setForRegional = (v: boolean) => setFields((f) => ({ ...f, for_regional: v, source_category: v ? null : f.source_category }))

  const togglePollutant = (p: string) =>
    set(
      'recommended_pollutants',
      fields.recommended_pollutants.includes(p)
        ? fields.recommended_pollutants.filter((x) => x !== p)
        : [...fields.recommended_pollutants, p],
    )

  const checklist = fields.checklist
  const setChecklistItem = (i: number, patch: Partial<ChecklistItem>) => {
    const next = [...checklist]
    next[i] = { ...next[i], ...patch }
    set('checklist', next)
  }
  const addChecklistItem = () =>
    set('checklist', [...checklist, { id: crypto.randomUUID(), label: '', type: 'boolean' as const }])
  const removeChecklistItem = (i: number) =>
    set(
      'checklist',
      checklist.filter((_, idx) => idx !== i),
    )

  const costRangeInvalid =
    fields.estimated_cost_min != null && fields.estimated_cost_max != null && fields.estimated_cost_min > fields.estimated_cost_max

  const submit = async (e: React.FormEvent) => {
    e.preventDefault()
    if (!fields.title.trim()) {
      setError('Title is required.')
      return
    }
    if (costRangeInvalid) {
      setError('Minimum cost cannot exceed maximum cost.')
      return
    }
    setBusy(true)
    setError(null)
    try {
      if (existing) {
        await updatePlaybook(existing.id, fields)
      } else {
        await createPlaybook(cityId, fields)
      }
      onSaved()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not save the playbook')
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={submit} className="space-y-3">
      <TextField label="Title" value={fields.title} onChange={(v) => set('title', v)} required />

      <CheckboxField
        label="Regional / non-local playbook (only shown for incidents classified 'regional')"
        checked={fields.for_regional}
        onChange={setForRegional}
      />

      <div className="grid grid-cols-2 gap-3">
        <SelectField
          label="Source category"
          value={fields.source_category ?? ''}
          onChange={(v) => set('source_category', v || null)}
          options={SOURCE_CATEGORY_OPTIONS}
          allowEmpty
        />
        <SelectField
          label="Action type"
          value={fields.action_type}
          onChange={(v) => set('action_type', v)}
          options={ACTION_TYPE_OPTIONS}
        />
        <SelectField
          label="Minimum evidence level"
          value={fields.min_evidence_level}
          onChange={(v) => set('min_evidence_level', v)}
          options={EVIDENCE_LEVEL_OPTIONS}
        />
        <SelectField
          label="Approval level"
          value={fields.approval_level}
          onChange={(v) => set('approval_level', v)}
          options={APPROVAL_LEVEL_OPTIONS}
        />
        <TextField label="Required team" value={fields.required_team ?? ''} onChange={(v) => set('required_team', v || null)} />
        <TextField
          label="Required equipment"
          value={fields.required_equipment ?? ''}
          onChange={(v) => set('required_equipment', v || null)}
        />
        <TextField
          label="Responsible agency type"
          value={fields.responsible_agency_type ?? ''}
          onChange={(v) => set('responsible_agency_type', v || null)}
        />
        <TextField label="Slug (optional, stable id)" value={fields.slug ?? ''} onChange={(v) => set('slug', v || null)} />
      </div>

      <TextAreaField label="Instructions" value={fields.instructions ?? ''} onChange={(v) => set('instructions', v || null)} />
      <TextAreaField label="Expected effect" value={fields.expected_effect ?? ''} onChange={(v) => set('expected_effect', v || null)} />
      <TextAreaField
        label="Known limitations"
        value={fields.known_limitations ?? ''}
        onChange={(v) => set('known_limitations', v || null)}
      />
      <TextAreaField label="Required proof" value={fields.required_proof ?? ''} onChange={(v) => set('required_proof', v || null)} />
      <TextAreaField
        label="Verification method"
        value={fields.verification_method ?? ''}
        onChange={(v) => set('verification_method', v || null)}
      />
      <SelectField
        label="Evidence basis"
        value={fields.evidence_basis ?? ''}
        onChange={(v) => set('evidence_basis', v || null)}
        options={EVIDENCE_BASIS_OPTIONS}
        allowEmpty
      />

      <p className="pt-1 text-xs font-semibold uppercase tracking-wide text-slate-400">Timing and cost</p>
      <div className="grid grid-cols-3 gap-3">
        <NumberField
          label="Deploy time (min)"
          value={fields.estimated_minutes}
          onChange={(v) => set('estimated_minutes', v)}
          min={0}
        />
        <NumberField
          label="Time to effect (h)"
          value={fields.expected_time_to_effect_hours}
          onChange={(v) => set('expected_time_to_effect_hours', v)}
          min={0}
          step={0.5}
        />
        <NumberField
          label="Effect duration (h)"
          value={fields.expected_duration_hours}
          onChange={(v) => set('expected_duration_hours', v)}
          min={0}
          step={0.5}
        />
        <NumberField
          label="Verification window (h)"
          value={fields.verification_window_hours}
          onChange={(v) => set('verification_window_hours', v)}
          min={0}
        />
        <NumberField label="Cost min" value={fields.estimated_cost_min} onChange={(v) => set('estimated_cost_min', v)} min={0} />
        <NumberField label="Cost max" value={fields.estimated_cost_max} onChange={(v) => set('estimated_cost_max', v)} min={0} />
      </div>
      {costRangeInvalid && (
        <p className="rounded-lg bg-status-critical/10 px-3 py-2 text-xs text-status-critical">
          Minimum cost cannot exceed maximum cost.
        </p>
      )}

      <p className="pt-1 text-xs font-semibold uppercase tracking-wide text-slate-400">Recommended pollutants (advisory only)</p>
      <div className="flex flex-wrap gap-x-3 gap-y-1.5 rounded-lg border border-slate-200 p-2.5">
        {POLLUTANT_OPTIONS.map((p) => (
          <CheckboxField
            key={p}
            label={p.toUpperCase()}
            checked={fields.recommended_pollutants.includes(p)}
            onChange={() => togglePollutant(p)}
          />
        ))}
      </div>

      <div className="flex items-center justify-between pt-1">
        <p className="text-xs font-semibold uppercase tracking-wide text-slate-400">Checklist</p>
        <button type="button" onClick={addChecklistItem} className="focus-ring text-xs font-semibold text-accent-700 hover:underline">
          + Add item
        </button>
      </div>
      {checklist.length === 0 ? (
        <p className="text-xs text-slate-400">No checklist items - the field app shows a plain confirm-and-submit step.</p>
      ) : (
        <div className="space-y-2">
          {checklist.map((item, i) => (
            <div key={item.id} className="flex items-end gap-2 rounded-lg border border-slate-200 p-2">
              <div className="flex-1">
                <TextField label="Label" value={item.label} onChange={(v) => setChecklistItem(i, { label: v })} />
              </div>
              <div className="w-32">
                <SelectField
                  label="Type"
                  value={item.type}
                  onChange={(v) => setChecklistItem(i, { type: v as 'boolean' | 'text' })}
                  options={[
                    { value: 'boolean', label: 'Yes/No' },
                    { value: 'text', label: 'Text' },
                  ]}
                />
              </div>
              <button
                type="button"
                onClick={() => removeChecklistItem(i)}
                aria-label="Remove item"
                className="focus-ring mb-1.5 rounded-lg p-1.5 text-slate-400 hover:bg-slate-100 hover:text-status-critical"
              >
                ✕
              </button>
            </div>
          ))}
        </div>
      )}

      {existing && (
        <NumberField
          label="Template version (bump only when you deliberately change this playbook)"
          value={fields.version}
          onChange={(v) => set('version', v ?? 1)}
          min={1}
        />
      )}

      <FormActions onCancel={onCancel} submitLabel={existing ? 'Save changes' : 'Create playbook'} busy={busy} error={error} />
    </form>
  )
}
