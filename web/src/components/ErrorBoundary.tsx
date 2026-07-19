import { Component, type ErrorInfo, type ReactNode } from 'react'
import { BUILD_INFO } from '../lib/env'

/**
 * Top-level error boundary (Phase 10, plan §15). React error boundaries
 * must be class components — there is no hook equivalent as of React 18.
 *
 * Catches a render-time exception ANYWHERE below it and shows a plain,
 * citizen-safe recovery screen instead of a blank white page — the
 * previous behaviour when nothing wrapped the app at all. Never shows the
 * raw error message or stack to the user; the build id is shown so a bug
 * report can be tied to an exact deployed version without exposing
 * anything internal.
 */
interface Props {
  children: ReactNode
}

interface State {
  hasError: boolean
}

export default class ErrorBoundary extends Component<Props, State> {
  state: State = { hasError: false }

  static getDerivedStateFromError(): State {
    return { hasError: true }
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    // eslint-disable-next-line no-console
    console.error('Unhandled UI error:', error, info.componentStack)
  }

  render() {
    if (this.state.hasError) {
      return (
        <div className="flex h-[100dvh] flex-col items-center justify-center gap-3 bg-cream px-4 text-center">
          <p className="text-2xl" aria-hidden>
            ⚠️
          </p>
          <p className="text-base font-semibold text-ink-800">Something went wrong.</p>
          <p className="max-w-sm text-sm text-ink-500">
            Please reload the page. If this keeps happening, tell us the build id below.
          </p>
          <button
            type="button"
            onClick={() => window.location.reload()}
            className="focus-ring rounded-lg bg-brand-700 px-4 py-2 text-sm font-semibold text-white hover:bg-brand-800"
          >
            Reload
          </button>
          <p className="text-[11px] text-ink-300">Build {BUILD_INFO.sha}</p>
        </div>
      )
    }
    return this.props.children
  }
}
