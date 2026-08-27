/**
 * A canvas that fills its parent, handles device pixel ratio, and redraws when
 * its `render` callback changes.
 *
 * Keeping this the only DOM-aware drawing code means the views stay pure
 * functions of (simulation snapshot -> pixels), and nothing in the simulation
 * ever learns that a screen exists.
 */

import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type MouseEvent as ReactMouseEvent,
} from 'react'

export type RenderFn = (ctx: CanvasRenderingContext2D, width: number, height: number) => void

interface Size {
  readonly width: number
  readonly height: number
}

interface CanvasSurfaceProps {
  readonly render: RenderFn
  readonly label: string
  /** Receives CSS-pixel coordinates relative to the canvas, plus its size, so
   * a caller can reuse the same geometry function it drew with. */
  readonly onClick?: (x: number, y: number, width: number, height: number) => void
}

export function CanvasSurface({ render, label, onClick }: CanvasSurfaceProps) {
  const hostRef = useRef<HTMLDivElement>(null)
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const [size, setSize] = useState<Size>({ width: 0, height: 0 })

  /**
   * Measure once on mount, then track changes.
   *
   * The direct measurement is not belt-and-braces. A ResizeObserver is the only
   * mechanism that reports a container growing for reasons unrelated to the
   * window, but it can go unfired entirely — a headless or background-rendered
   * tab is one case — and depending on it alone leaves the canvas silently at
   * its 300x150 default, drawing nothing, with no error anywhere. Reading the
   * box directly is what guarantees a first paint; the observer and the window
   * listener only keep it current.
   */
  useLayoutEffect(() => {
    const host = hostRef.current
    if (host === null) return

    const measure = () => {
      const rect = host.getBoundingClientRect()
      const width = Math.floor(rect.width)
      const height = Math.floor(rect.height)
      setSize((current) =>
        current.width === width && current.height === height ? current : { width, height },
      )
    }

    measure()

    const observer = new ResizeObserver(measure)
    observer.observe(host)
    window.addEventListener('resize', measure)
    return () => {
      observer.disconnect()
      window.removeEventListener('resize', measure)
    }
  }, [])

  useEffect(() => {
    const canvas = canvasRef.current
    if (canvas === null || size.width === 0 || size.height === 0) return

    const dpr = window.devicePixelRatio || 1
    canvas.width = Math.floor(size.width * dpr)
    canvas.height = Math.floor(size.height * dpr)
    canvas.style.width = `${size.width}px`
    canvas.style.height = `${size.height}px`

    const ctx = canvas.getContext('2d')
    if (ctx === null) return

    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    ctx.clearRect(0, 0, size.width, size.height)
    render(ctx, size.width, size.height)
  }, [render, size])

  const handleClick = (event: ReactMouseEvent<HTMLCanvasElement>) => {
    if (onClick === undefined) return
    const bounds = event.currentTarget.getBoundingClientRect()
    onClick(event.clientX - bounds.left, event.clientY - bounds.top, size.width, size.height)
  }

  return (
    <div className="canvas-host" ref={hostRef}>
      <canvas
        ref={canvasRef}
        aria-label={label}
        onClick={handleClick}
        style={onClick === undefined ? undefined : { cursor: 'pointer' }}
      />
    </div>
  )
}
