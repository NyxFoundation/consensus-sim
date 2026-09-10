/**
 * The validator's colour swatch — always paired with the validator's name
 * or initial, never a colour alone (tokens.css --validator-N). One
 * definition for the state table, the chain-state and vote tables, the
 * attack, parameter and intervention panels and the tree legend.
 */

import type { ValidatorIndex } from '../../domain'
import { validatorColor } from '../validatorColor'

export interface ValidatorDotProps {
  readonly validator: ValidatorIndex
}

export function ValidatorDot({ validator }: ValidatorDotProps) {
  return <span className="validator-dot" style={{ background: validatorColor(validator) }} />
}
