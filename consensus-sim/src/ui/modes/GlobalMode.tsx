/**
 * Global mode (全体モード): the chain view on the left and the network view
 * on the right, side by side. Both panes are the real mode components, so
 * every interaction (perspective toggle, validator selection, hover views)
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
        />
      </div>
    </section>
  )
}
