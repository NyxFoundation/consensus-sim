/**
 * The discrete-event scheduler.
 *
 * Ordering is (time, insertion sequence). The sequence number is what makes the
 * queue deterministic: two events scheduled for the same instant always come
 * out in the order they went in, so a run never depends on heap-internal
 * tie-breaking. Without it, adding an unrelated event could silently reorder
 * message delivery and change the outcome of a scenario.
 */

import type { Time } from './types'

export interface ScheduledEvent<P> {
  readonly time: Time
  readonly seq: number
  readonly payload: P
}

export class EventQueue<P> {
  private readonly heap: ScheduledEvent<P>[] = []
  private nextSeq = 0

  get size(): number {
    return this.heap.length
  }

  /** Time of the earliest pending event, or null when the queue is empty. */
  peekTime(): Time | null {
    const top = this.heap[0]
    return top === undefined ? null : top.time
  }

  push(time: Time, payload: P): void {
    const event: ScheduledEvent<P> = { time, seq: this.nextSeq++, payload }
    this.heap.push(event)
    this.siftUp(this.heap.length - 1)
  }

  pop(): ScheduledEvent<P> | null {
    const top = this.heap[0]
    if (top === undefined) return null

    const last = this.heap.pop() as ScheduledEvent<P>
    if (this.heap.length > 0) {
      this.heap[0] = last
      this.siftDown(0)
    }
    return top
  }

  clear(): void {
    this.heap.length = 0
    this.nextSeq = 0
  }

  private static isBefore<P>(a: ScheduledEvent<P>, b: ScheduledEvent<P>): boolean {
    return a.time !== b.time ? a.time < b.time : a.seq < b.seq
  }

  private siftUp(start: number): void {
    let index = start
    const item = this.heap[index] as ScheduledEvent<P>
    while (index > 0) {
      const parentIndex = (index - 1) >> 1
      const parent = this.heap[parentIndex] as ScheduledEvent<P>
      if (!EventQueue.isBefore(item, parent)) break
      this.heap[index] = parent
      index = parentIndex
    }
    this.heap[index] = item
  }

  private siftDown(start: number): void {
    let index = start
    const size = this.heap.length
    const item = this.heap[index] as ScheduledEvent<P>

    for (;;) {
      const left = index * 2 + 1
      if (left >= size) break
      const right = left + 1
      const leftChild = this.heap[left] as ScheduledEvent<P>
      const rightChild = right < size ? (this.heap[right] as ScheduledEvent<P>) : undefined

      const swapIndex =
        rightChild !== undefined && EventQueue.isBefore(rightChild, leftChild) ? right : left
      const swapChild = this.heap[swapIndex] as ScheduledEvent<P>

      if (!EventQueue.isBefore(swapChild, item)) break
      this.heap[index] = swapChild
      index = swapIndex
    }

    this.heap[index] = item
  }
}
