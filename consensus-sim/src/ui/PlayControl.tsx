/**
 * Auto-play control (自動再生, 必須 31): one button in the slot bar, shown
 * while an attack is bound. 実行開始 starts the run from slot 0 (also after
 * a rewind to slot 0, which restarts the run), 一時停止 pauses it, 再開
 * continues from wherever it stopped — the stop at the slot the goal was
 * achieved included, so the run can be carried on to its end slot. The end
 * slot is read out beside it. The timer and the stop rules live in
 * useSimulation; this component only names the state.
 */

import { Button } from './components/Button'
import { Hint } from './components/Hint'
import type { SimulationSession } from './useSimulation'

export interface PlayControlProps {
  readonly session: SimulationSession
}

export function PlayControl({ session }: PlayControlProps) {
  const { attack, playing, cursor, throughSlot } = session
  if (attack === undefined || throughSlot === undefined) return null
  const atEnd = cursor >= throughSlot
  // From slot 0 the run starts (a rewound run restarts from its anchor);
  // from anywhere later it resumes.
  const label = playing ? '一時停止' : cursor === 0 ? '実行開始' : '再開'
  return (
    <div className="play-control" role="group" aria-label="自動再生">
      <Button
        variant={playing ? 'default' : 'primary'}
        className="play-toggle"
        disabled={!playing && atEnd}
        onClick={() => (playing ? session.pause() : session.play())}
      >
        {label}
      </Button>
      <span className="readout play-readout">
        {playing ? '再生中 ' : ''}終了 s{throughSlot}
      </span>
      <Hint text="攻撃の自動再生。実行開始でスロットが一定間隔で自動的に進み、攻撃目標が達成と判定されたスロット、または既定実行構成の終了スロット（攻撃区画で変更可）で停止。一時停止・再開ができ、停止後はカーソルでの巻き戻し・介入の追加・プロトコルパラメータの変更が従来どおり可能。達成で停止した後の再開は終了スロットまで進める" />
    </div>
  )
}
