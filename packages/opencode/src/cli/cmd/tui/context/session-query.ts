import type { Config } from "@opencode-ai/sdk/v2"

export function sessionQuery(cfg?: Config, now = Date.now()) {
  const days = cfg?.session_history_days ?? 30
  const limit = cfg?.session_history_limit

  return {
    roots: true,
    ...(days > 0 ? { start: now - days * 24 * 60 * 60 * 1000 } : {}),
    ...(limit && limit > 0 ? { limit } : {}),
  }
}
