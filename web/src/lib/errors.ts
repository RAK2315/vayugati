/**
 * Citizen-safe error display (Phase 10, plan §15: "citizen-safe error
 * messages... no raw database errors shown to users").
 *
 * Always returns a fixed, friendly fallback — never the underlying
 * error's own `.message`, which may be a raw PostgREST/Postgres error
 * naming an internal table, column, or constraint (`e.message` is still
 * logged to the console in dev for debugging). Command/field surfaces are
 * unaffected by this — those are internal operators who benefit from
 * seeing the real error; this exists specifically for public-facing
 * citizen components, which should never need to explain a database term
 * to someone who reported an air-quality problem.
 */
export function citizenSafeErrorMessage(e: unknown, fallback = 'Something went wrong. Please try again.'): string {
  if (import.meta.env.DEV) {
    // eslint-disable-next-line no-console
    console.error(e)
  }
  return fallback
}
