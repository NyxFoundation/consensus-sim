/**
 * Global display (全体表示): the chain display on the left and the network
 * display on the right, side by side. Both panes are the real display
 * components, so every interaction (state-table cell expansion, hover views)
 * behaves identically here.
 */

import type { Intervention } from '../../domain'
import { ChainMode, type ChainModeProps } from './ChainMode'
import { NetworkMode } from './NetworkMode'

export interface GlobalModeProps extends ChainModeProps {
  readonly interventions?: readonly Intervention[] | undefined
}

export function GlobalMode({ interventions, ...chain }: GlobalModeProps) {
  return (
    <section className="global-mode">
      <div className="global-pane">
        <h2 className="pane-title">チェーン</h2>
        <ChainMode {...chain} />
      </div>
      <div className="global-pane">
        <h2 className="pane-title">ネットワーク</h2>
        <NetworkMode
          state={chain.state}
          config={chain.config}
          delivery={chain.delivery}
          interventions={interventions}
        />
      </div>
    </section>
  )
}
