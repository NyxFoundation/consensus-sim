/**
 * Global display (全体表示): the chain display on the left and the network
 * display on the right, side by side. Both panes are the real display
 * components, so every interaction (state-table cell expansion, hover views)
 * behaves identically here.
 */

import { ChainMode, type ChainModeProps } from './ChainMode'
import { NetworkMode } from './NetworkMode'

export type GlobalModeProps = ChainModeProps

export function GlobalMode(props: GlobalModeProps) {
  return (
    <section className="global-mode">
      <div className="global-pane">
        <h2 className="pane-title">チェーン</h2>
        <ChainMode {...props} />
      </div>
      <div className="global-pane">
        <h2 className="pane-title">ネットワーク</h2>
        <NetworkMode
          state={props.state}
          validatorCount={props.validatorCount}
          delivery={props.delivery}
        />
      </div>
    </section>
  )
}
