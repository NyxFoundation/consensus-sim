/**
 * Auto-play control (自動再生) in the slot bar: the speed (再生速度, ×0.5 /
 * ×1 / ×2) and one toggle. With an attack bound (必須 31), 実行開始 starts
 * the run from slot 0 (also after a rewind to slot 0, which restarts the
 * run), 一時停止 pauses it, 再開 continues from wherever it stopped — the
 * stop at the slot the goal was achieved included, so the run can be
 * carried on to its end slot, which is read out beside it. Without an
 * attack (任意), 自動再生 advances the scenario FREE_PLAY_SPAN slots from the
 * cursor and stops; pressing again continues. The timer and the stop rules
 * live in useSimulation; this component only names the state.
 */

import { Button } from './components/Button'
import { Hint } from './components/Hint'
import { Segmented } from './components/Segmented'
import type { SegmentedOption } from './components/Segmented'
import type { PlaySpeed, SimulationSession } from './useSimulation'

export interface PlayControlProps {
  readonly session: SimulationSession
}

const SPEED_OPTIONS: readonly SegmentedOption<PlaySpeed>[] = [
  { key: 'slow', label: '×0.5' },
  { key: 'normal', label: '×1' },
  { key: 'fast', label: '×2' },
]

export function PlayControl({ session }: PlayControlProps) {
  const { attack, playing, cursor, playEnd, speed } = session
  const withAttack = attack !== undefined
  const atEnd = withAttack && cursor >= playEnd
  // With an attack: from slot 0 the run starts (a rewound run restarts from
  // its anchor), from anywhere later it resumes. Without one there is no run
  // to resume — every start is a plain auto-play from the cursor.
  const label = playing
    ? '一時停止'
    : withAttack
      ? cursor === 0
        ? '実行開始'
        : '再開'
      : '自動再生'
  return (
    <div className="play-control" role="group" aria-label="自動再生">
      <Segmented
        label="再生速度"
        className="play-speed"
        size="sm"
        value={speed}
        options={SPEED_OPTIONS}
        onChange={session.setSpeed}
      />
      <Button
        variant={playing ? 'default' : 'primary'}
        className="play-toggle"
        aria-keyshortcuts="Space"
        disabled={!playing && atEnd}
        onClick={() => (playing ? session.pause() : session.play())}
      >
        {label}
      </Button>
      {(withAttack || playing) && (
        <span className="readout play-readout">
          {playing ? '再生中 ' : ''}終了 s{playEnd}
        </span>
      )}
      <Hint text="自動再生。スロットが一定間隔（×1 = 0.6 秒、×0.5 / ×2 で速度調整）で自動的に進み、一時停止・再開ができる。攻撃を組み込んだシナリオでは実行開始で始まり、攻撃目標が達成と判定されたスロット、または既定実行構成の終了スロット（攻撃区画で変更可）で停止。達成で停止した後の再開は終了スロットまで進める。攻撃のないシナリオでは開始位置から 16 スロット（4 エポック）進んで止まり、もう一度押すと続きを再生。停止後はカーソルでの巻き戻し・介入の追加・プロトコルパラメータの変更が従来どおり可能。Space キーでも開始・一時停止できる" />
    </div>
  )
}
