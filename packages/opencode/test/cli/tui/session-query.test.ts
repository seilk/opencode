import { describe, expect, test } from "bun:test"
import { sessionQuery } from "../../../src/cli/cmd/tui/context/session-query"

describe("sessionQuery", () => {
  test("uses the default 30 day root-session window", () => {
    const query = sessionQuery(undefined, 2_000_000_000_000)

    expect(query).toEqual({
      roots: true,
      start: 2_000_000_000_000 - 30 * 24 * 60 * 60 * 1000,
    })
  })

  test("adds a count limit when configured", () => {
    const query = sessionQuery({ session_history_limit: 12 }, 2_000_000_000_000)

    expect(query).toEqual({
      roots: true,
      start: 2_000_000_000_000 - 30 * 24 * 60 * 60 * 1000,
      limit: 12,
    })
  })

  test("omits the time filter when days are disabled", () => {
    const query = sessionQuery({ session_history_days: 0 }, 2_000_000_000_000)

    expect(query).toEqual({
      roots: true,
    })
  })

  test("omits the count limit when it is disabled", () => {
    const query = sessionQuery({ session_history_limit: 0 }, 2_000_000_000_000)

    expect(query).toEqual({
      roots: true,
      start: 2_000_000_000_000 - 30 * 24 * 60 * 60 * 1000,
    })
  })

  test("combines days and count settings", () => {
    const query = sessionQuery({ session_history_days: 7, session_history_limit: 5 }, 2_000_000_000_000)

    expect(query).toEqual({
      roots: true,
      start: 2_000_000_000_000 - 7 * 24 * 60 * 60 * 1000,
      limit: 5,
    })
  })
})
