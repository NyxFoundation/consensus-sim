/**
 * Stable colour per validator index (0..9). Colour is always accompanied by
 * the validator number itself (chips carry the digit), so identity never
 * rides on colour alone; the ramp only helps the eye group marks quickly.
 */

const VALIDATOR_COLORS: readonly string[] = [
  '#2a78d6',
  '#eb6834',
  '#1baf7a',
  '#9256d9',
  '#c8a012',
  '#d0489c',
  '#188fa3',
  '#8a6b45',
  '#5b64d6',
  '#6d7a12',
]

export function validatorColor(validator: number): string {
  return VALIDATOR_COLORS[validator % VALIDATOR_COLORS.length] ?? '#898781'
}
