import { useState } from 'react'
import type { Database } from '../../lib/database.types'
import { fetchAllWardsAqi } from '../../lib/data'
import { listAssignableOfficers, type AssignableOfficer } from '../../lib/incidents'
import { PLAYBOOK_ACTION_TYPE_LABEL, SOURCE_CATEGORY_LABEL } from '../../lib/incidentRules'
import {
  createRegistryEntry,
  updateRegistryEntry,
  type EscalationHierarchyEntry,
  type RegistryFormFields,
  type ResponsibilityRegistryRow,
} from '../../lib/ops'
import { useAsync } from '../../lib/useAsync'
import { CheckboxField, FormActions, SelectField, TextField } from './formFields'

type SourceCategory = Database['public']['Enums']['source_category']

const SOURCE_CATEGORY_OPTIONS = (Object.entries(SOURCE_CATEGORY_LABEL) as [SourceCategory, string][]).map(
  ([value, label]) => ({ value, label }),
)
const MAPPING_CONFIDENCE_OPTIONS = [
  { value: 'verified', label: 'Verified' },
  { value: 'estimated', label: 'Estimated' },
  { value: 'legacy', label: 'Legacy' },
]

function toFields(row: ResponsibilityRegistryRow | null): RegistryFormFields {
  const contactChannel = (row?.contact_channel as { phone?: string; email?: string } | null) ?? {}
  const escalationHierarchy = (row?.escalation_hierarchy as EscalationHierarchyEntry[] | null) ?? []
  return {
    source_category: row?.source_category ?? null,
    ward_id: row?.ward_id ?? null,
    asset_description: row?.asset_description ?? null,
    owner_name: row?.owner_name ?? null,
    regulating_authority: row?.regulating_authority ?? null,
    division_zone: row?.division_zone ?? null,
    responsible_officer: row?.responsible_officer ?? null,
    escalation_contact: row?.escalation_contact ?? null,
    team_name: row?.team_name ?? null,
    backup_agency: row?.backup_agency ?? null,
    backup_team: row?.backup_team ?? null,
    backup_officer: row?.backup_officer ?? null,
    zone_description: row?.zone_description ?? null,
    contact_channel: contactChannel,
    supported_intervention_types: row?.supported_intervention_types ?? [],
    working_hours: (row?.working_hours as string | null) ?? null,
    escalation_hierarchy: escalationHierarchy,
    mapping_confidence: row?.mapping_confidence ?? 'estimated',
    mapping_source: row?.mapping_source ?? null,
  }
}

function OfficerSelect({
  label,
  value,
  onChange,
  officers,
}: {
  label: string
  value: string | null
  onChange: (v: string | null) => void
  officers: AssignableOfficer[]
}) {
  return (
    <SelectField
      label={label}
      value={value ?? ''}
      onChange={(v) => onChange(v || null)}
      allowEmpty
      options={officers.map((o) => ({ value: o.id, label: o.full_name ?? `Officer ${o.id.slice(0, 8)}` }))}
    />
  )
}

export default function RegistryEntryForm({
  cityId,
  existing,
  onSaved,
  onCancel,
}: {
  cityId: number
  existing: ResponsibilityRegistryRow | null
  onSaved: () => void
  onCancel: () => void
}) {
  const [fields, setFields] = useState<RegistryFormFields>(() => toFields(existing))
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const wardsState = useAsync(fetchAllWardsAqi, [])
  const officersState = useAsync(() => listAssignableOfficers(), [])
  const wards = wardsState.data ?? []
  const officers = officersState.data ?? []

  const set = <K extends keyof RegistryFormFields>(key: K, value: RegistryFormFields[K]) =>
    setFields((f) => ({ ...f, [key]: value }))

  const toggleInterventionType = (type: string) => {
    set(
      'supported_intervention_types',
      fields.supported_intervention_types.includes(type)
        ? fields.supported_intervention_types.filter((t) => t !== type)
        : [...fields.supported_intervention_types, type],
    )
  }

  const escalationRows = fields.escalation_hierarchy
  const setEscalationRow = (i: number, patch: Partial<EscalationHierarchyEntry>) => {
    const next = [...escalationRows]
    next[i] = { ...next[i], ...patch }
    set('escalation_hierarchy', next)
  }
  const addEscalationRow = () =>
    set('escalation_hierarchy', [...escalationRows, { level: escalationRows.length + 1, role: '', contact: '' }])
  const removeEscalationRow = (i: number) =>
    set(
      'escalation_hierarchy',
      escalationRows.filter((_, idx) => idx !== i),
    )

  const submit = async (e: React.FormEvent) => {
    e.preventDefault()
    setBusy(true)
    setError(null)
    try {
      if (existing) {
        await updateRegistryEntry(existing.id, fields)
      } else {
        await createRegistryEntry(cityId, fields)
      }
      onSaved()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not save the registry entry')
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={submit} className="space-y-3">
      <div className="grid grid-cols-2 gap-3">
        <SelectField
          label="Source category"
          value={fields.source_category ?? ''}
          onChange={(v) => set('source_category', v || null)}
          options={SOURCE_CATEGORY_OPTIONS}
          allowEmpty
        />
        <SelectField
          label="Ward (blank = city-wide)"
          value={fields.ward_id != null ? String(fields.ward_id) : ''}
          onChange={(v) => set('ward_id', v ? Number(v) : null)}
          options={wards.map((w) => ({ value: String(w.id), label: w.name }))}
          allowEmpty
        />
      </div>
      <TextField
        label="Regulating authority"
        value={fields.regulating_authority ?? ''}
        onChange={(v) => set('regulating_authority', v || null)}
      />
      <div className="grid grid-cols-2 gap-3">
        <TextField label="Division / zone" value={fields.division_zone ?? ''} onChange={(v) => set('division_zone', v || null)} />
        <TextField label="Zone description" value={fields.zone_description ?? ''} onChange={(v) => set('zone_description', v || null)} />
        <TextField label="Owner name" value={fields.owner_name ?? ''} onChange={(v) => set('owner_name', v || null)} />
        <TextField label="Asset description" value={fields.asset_description ?? ''} onChange={(v) => set('asset_description', v || null)} />
        <TextField label="Team name" value={fields.team_name ?? ''} onChange={(v) => set('team_name', v || null)} />
        <OfficerSelect
          label="Responsible officer"
          value={fields.responsible_officer}
          onChange={(v) => set('responsible_officer', v)}
          officers={officers}
        />
        <TextField label="Escalation contact" value={fields.escalation_contact ?? ''} onChange={(v) => set('escalation_contact', v || null)} />
        <TextField label="Backup agency" value={fields.backup_agency ?? ''} onChange={(v) => set('backup_agency', v || null)} />
        <TextField label="Backup team" value={fields.backup_team ?? ''} onChange={(v) => set('backup_team', v || null)} />
        <OfficerSelect
          label="Backup officer"
          value={fields.backup_officer}
          onChange={(v) => set('backup_officer', v)}
          officers={officers}
        />
      </div>

      <p className="pt-1 text-xs font-semibold uppercase tracking-wide text-slate-400">Contact channel</p>
      <div className="grid grid-cols-2 gap-3">
        <TextField
          label="Phone"
          value={fields.contact_channel.phone ?? ''}
          onChange={(v) => set('contact_channel', { ...fields.contact_channel, phone: v || undefined })}
        />
        <TextField
          label="Email"
          value={fields.contact_channel.email ?? ''}
          onChange={(v) => set('contact_channel', { ...fields.contact_channel, email: v || undefined })}
        />
      </div>
      <TextField
        label="Working hours (free text, e.g. Mon-Sat 09:00-18:00 IST)"
        value={fields.working_hours ?? ''}
        onChange={(v) => set('working_hours', v || null)}
      />

      <p className="pt-1 text-xs font-semibold uppercase tracking-wide text-slate-400">Supported intervention types</p>
      <div className="grid grid-cols-2 gap-x-3 gap-y-1.5 rounded-lg border border-slate-200 p-2.5">
        {Object.entries(PLAYBOOK_ACTION_TYPE_LABEL).map(([type, label]) => (
          <CheckboxField
            key={type}
            label={label}
            checked={fields.supported_intervention_types.includes(type)}
            onChange={() => toggleInterventionType(type)}
          />
        ))}
      </div>
      <p className="text-xs text-slate-400">Leave all unchecked to allow every intervention type (no narrowing).</p>

      <div className="flex items-center justify-between pt-1">
        <p className="text-xs font-semibold uppercase tracking-wide text-slate-400">Escalation hierarchy</p>
        <button type="button" onClick={addEscalationRow} className="focus-ring text-xs font-semibold text-accent-700 hover:underline">
          + Add level
        </button>
      </div>
      {escalationRows.length === 0 ? (
        <p className="text-xs text-slate-400">No escalation levels configured.</p>
      ) : (
        <div className="space-y-2">
          {escalationRows.map((row, i) => (
            <div key={i} className="flex items-end gap-2 rounded-lg border border-slate-200 p-2">
              <div className="w-16">
                <TextField
                  label="Level"
                  value={String(row.level)}
                  onChange={(v) => setEscalationRow(i, { level: Number(v) || 0 })}
                />
              </div>
              <div className="flex-1">
                <TextField label="Role" value={row.role} onChange={(v) => setEscalationRow(i, { role: v })} />
              </div>
              <div className="flex-1">
                <TextField label="Contact" value={row.contact} onChange={(v) => setEscalationRow(i, { contact: v })} />
              </div>
              <button
                type="button"
                onClick={() => removeEscalationRow(i)}
                aria-label="Remove level"
                className="focus-ring mb-1.5 rounded-lg p-1.5 text-slate-400 hover:bg-slate-100 hover:text-status-critical"
              >
                ✕
              </button>
            </div>
          ))}
        </div>
      )}

      <div className="grid grid-cols-2 gap-3 pt-1">
        <SelectField
          label="Mapping confidence"
          value={fields.mapping_confidence}
          onChange={(v) => set('mapping_confidence', v)}
          options={MAPPING_CONFIDENCE_OPTIONS}
        />
        <TextField label="Mapping source" value={fields.mapping_source ?? ''} onChange={(v) => set('mapping_source', v || null)} />
      </div>

      <FormActions onCancel={onCancel} submitLabel={existing ? 'Save changes' : 'Create entry'} busy={busy} error={error} />
    </form>
  )
}
