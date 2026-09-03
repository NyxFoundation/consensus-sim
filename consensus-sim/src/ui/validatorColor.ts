/**
 * Stable colour per validator index (0..9). Colour is always accompanied by
 * the validator's name or its initial kana (chips carry the initial), so
 * identity never rides on colour alone; the ramp only helps the eye group
 * marks quickly. The actual hues live once in src/ui/tokens.css
 * (--validator-0 … --validator-9); this only picks the token by index, so
 * every inline `style={{ background: validatorColor(v) }}` resolves through
 * the same design tokens as the rest of the UI.
 */

const VALIDATOR_COUNT = 10

export function validatorColor(validator: number): string {
  const index = ((validator % VALIDATOR_COUNT) + VALIDATOR_COUNT) % VALIDATOR_COUNT
  return `var(--validator-${index}, var(--validator-fallback))`
}
