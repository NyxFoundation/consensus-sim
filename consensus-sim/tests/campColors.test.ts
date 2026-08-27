import { describe, expect, it } from 'vitest'
import { assignCampSlots, createRegistry, OTHER } from '../src/ui/campColors'
import type { Camp } from '../src/ui/divergence'

function camp(head: string, count = 1): Camp {
  return { head, count }
}

describe('assignCampSlots', () => {
  it('should assign nothing when the network is not forked', () => {
    expect(assignCampSlots(createRegistry(), []).size).toBe(0)
  })

  it('should hand out slots in first-seen order', () => {
    const assigned = assignCampSlots(createRegistry(), [camp('a'), camp('b')])

    expect(assigned.get('a')).toBe(1)
    expect(assigned.get('b')).toBe(2)
  })

  /**
   * Colour follows the branch, never its rank. Assigning by size would repaint
   * both camps at the instant a minority overtook a majority, which is exactly
   * the moment the viewer is trying to read.
   */
  it('should keep a camp colour when it overtakes the other', () => {
    const registry = createRegistry()
    assignCampSlots(registry, [camp('a', 9), camp('b', 1)])
    const after = assignCampSlots(registry, [camp('b', 9), camp('a', 1)])

    expect(after.get('a')).toBe(1)
    expect(after.get('b')).toBe(2)
  })

  it('should keep a colour across a spell with no fork at all', () => {
    const registry = createRegistry()
    assignCampSlots(registry, [camp('a')])
    assignCampSlots(registry, [])
    const returned = assignCampSlots(registry, [camp('a')])

    expect(returned.get('a')).toBe(1)
  })

  it('should fold a fourth camp into the shared colour', () => {
    const assigned = assignCampSlots(createRegistry(), [
      camp('a'),
      camp('b'),
      camp('c'),
      camp('d'),
    ])

    expect(assigned.get('d')).toBe(OTHER)
  })

  it('should start over on a fresh registry', () => {
    expect(assignCampSlots(createRegistry(), [camp('z')]).get('z')).toBe(1)
  })
})
