import { describe, expect, it } from 'vitest'
import { EventQueue } from '../src/core/eventQueue'

describe('EventQueue', () => {
  it('should pop events in ascending time order when pushed out of order', () => {
    const queue = new EventQueue<string>()
    queue.push(30, 'c')
    queue.push(10, 'a')
    queue.push(20, 'b')

    expect([queue.pop()?.payload, queue.pop()?.payload, queue.pop()?.payload]).toEqual([
      'a',
      'b',
      'c',
    ])
  })

  it('should preserve insertion order when events share a timestamp', () => {
    const queue = new EventQueue<number>()
    for (let i = 0; i < 50; i++) queue.push(100, i)

    const popped: number[] = []
    for (;;) {
      const event = queue.pop()
      if (event === null) break
      popped.push(event.payload)
    }

    expect(popped).toEqual(Array.from({ length: 50 }, (_, i) => i))
  })

  it('should report null for peekTime and pop when empty', () => {
    const queue = new EventQueue<string>()
    expect(queue.peekTime()).toBeNull()
    expect(queue.pop()).toBeNull()
    expect(queue.size).toBe(0)
  })

  it('should interleave correctly when pushing while draining', () => {
    const queue = new EventQueue<number>()
    queue.push(5, 5)
    queue.push(15, 15)
    expect(queue.pop()?.time).toBe(5)

    queue.push(10, 10)
    expect(queue.pop()?.time).toBe(10)
    expect(queue.pop()?.time).toBe(15)
  })
})
