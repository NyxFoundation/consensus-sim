/**
 * The wire format of the simulated network.
 *
 * Every protocol message carries a `layer` tag. Today the union has one member;
 * when a second layer arrives it joins here, and each layer narrows on the tag.
 * Keeping this a discriminated union rather than an opaque payload is what lets
 * the compiler check that a layer only ever handles its own messages.
 */

import type { NodeId } from '../core/types'
import type { GasperMessage } from './gasper/types'

export type ProtocolMessage = GasperMessage

export type LayerId = ProtocolMessage['layer']

export interface Envelope {
  readonly from: NodeId
  readonly message: ProtocolMessage
}
