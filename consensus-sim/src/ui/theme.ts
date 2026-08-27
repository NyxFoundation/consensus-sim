/**
 * The two surfaces and the ink and series steps that sit on each.
 *
 * Dark is not an inversion of light. Each mode takes its own step from the same
 * hue ramps, chosen for that surface's lightness band — flipping the light
 * values would drop several of them below the contrast floor. The two columns
 * are validated separately against their own surface.
 */

export type ThemeMode = 'light' | 'dark'

export interface Palette {
  readonly surface: string
  readonly plane: string
  readonly inkPrimary: string
  readonly inkSecondary: string
  readonly inkMuted: string
  readonly gridline: string
  readonly baseline: string
  /** Fill for a block in the fork tree — neutral; state rides on the stroke. */
  readonly blockFill: string
  /** Fill for a validator cell that agrees with the observed node. */
  readonly neutralCell: string
  /**
   * Categorical slots, in fixed order. Only ever assigned to *contested* heads,
   * never cycled: a fourth contested head folds into `otherSeries`.
   *
   * Three is not an arbitrary cap. These three are the slots that clear the
   * all-pairs colour-vision gates in both modes — and every cell in the grid can
   * end up beside every other, so all-pairs is the applicable test, not the
   * adjacent-pairs one. A fourth slot would put yellow next to orange and fail.
   *
   * Validated with the data-viz palette validator:
   *   light  worst all-pairs CVD ΔE 9.2, normal-vision 24.0
   *   dark   worst all-pairs CVD ΔE 9.4, normal-vision 20.9
   * Light slot 3 (#1baf7a) sits at 2.74:1 against the light surface, below the
   * 3:1 line. The required relief is a visible label: every coloured category
   * appears in the legend with its short hash and node count, so no category is
   * ever identified by colour alone. Do not "fix" the contrast by re-stepping
   * the hue without re-running the validator on the whole set.
   */
  readonly series: readonly [string, string, string]
  readonly otherSeries: string
  readonly statusGood: string
  readonly statusWarning: string
  readonly statusCritical: string
  readonly border: string
}

const LIGHT: Palette = {
  surface: '#fcfcfb',
  plane: '#f9f9f7',
  inkPrimary: '#0b0b0b',
  inkSecondary: '#52514e',
  inkMuted: '#898781',
  gridline: '#e1e0d9',
  baseline: '#c3c2b7',
  blockFill: '#f0efec',
  neutralCell: '#e1e0d9',
  series: ['#2a78d6', '#eb6834', '#1baf7a'],
  otherSeries: '#898781',
  statusGood: '#0ca30c',
  statusWarning: '#fab219',
  statusCritical: '#d03b3b',
  border: 'rgba(11,11,11,0.10)',
}

const DARK: Palette = {
  surface: '#1a1a19',
  plane: '#0d0d0d',
  inkPrimary: '#ffffff',
  inkSecondary: '#c3c2b7',
  inkMuted: '#898781',
  gridline: '#2c2c2a',
  baseline: '#383835',
  blockFill: '#2c2c2a',
  neutralCell: '#383835',
  series: ['#3987e5', '#d95926', '#199e70'],
  otherSeries: '#898781',
  statusGood: '#0ca30c',
  statusWarning: '#fab219',
  statusCritical: '#d03b3b',
  border: 'rgba(255,255,255,0.10)',
}

export function paletteFor(mode: ThemeMode): Palette {
  return mode === 'dark' ? DARK : LIGHT
}

/** The hexes the palette validator is run against, per mode. */
export const VALIDATED_SETS: Readonly<Record<ThemeMode, readonly string[]>> = {
  light: LIGHT.series,
  dark: DARK.series,
}
