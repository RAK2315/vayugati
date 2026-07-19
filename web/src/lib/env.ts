/**
 * Environment and build identity (Phase 10, plan §4/§15).
 *
 * Vayu Gati supports four environments — local, test, staging (pilot),
 * production — as SEPARATE Supabase projects and separate deployments, not
 * a runtime-switched single database. `VITE_ENVIRONMENT` only affects
 * client-side DISPLAY and behaviour (a non-production banner, log
 * verbosity) — which project the app actually talks to is entirely decided
 * by which `VITE_SUPABASE_URL` was baked into the build, not by this value.
 * See docs/ENVIRONMENT_VARIABLES.md for the full separation model.
 */

export type Environment = 'local' | 'test' | 'staging' | 'production'

const RAW = (import.meta.env.VITE_ENVIRONMENT ?? 'local').toLowerCase()

export const ENVIRONMENT: Environment = (
  ['local', 'test', 'staging', 'production'].includes(RAW) ? RAW : 'local'
) as Environment

export const IS_PRODUCTION = ENVIRONMENT === 'production'

/** Short git SHA + build timestamp, injected at build time (vite.config.ts).
 *  Shown in the command-centre footer and included in error reports so a
 *  bug report can be tied to an exact deployed build. */
export const BUILD_INFO = {
  sha: typeof __BUILD_SHA__ !== 'undefined' ? __BUILD_SHA__ : 'unknown',
  builtAt: typeof __BUILD_TIME__ !== 'undefined' ? __BUILD_TIME__ : null,
  environment: ENVIRONMENT,
}
