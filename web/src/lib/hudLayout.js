export const HUD_REFERENCE_WIDTH = 1920
export const HUD_REFERENCE_HEIGHT = 1080

/**
 * Uniformly scales the 1920x1080 reference canvas to fit inside the real
 * viewport, capped by whichever axis is tighter, and centers the result
 * (letterboxing the other axis).
 */
export function computeCanvasFit(viewportWidth, viewportHeight) {
  const scale = Math.min(viewportWidth / HUD_REFERENCE_WIDTH, viewportHeight / HUD_REFERENCE_HEIGHT)
  const offsetX = (viewportWidth - HUD_REFERENCE_WIDTH * scale) / 2
  const offsetY = (viewportHeight - HUD_REFERENCE_HEIGHT * scale) / 2
  return { scale, offsetX, offsetY }
}

/** Builds the CSS transform for a positioned element's tilt/rotate/scale. */
export function layoutTransform(layout) {
  return `perspective(1100px) rotateY(${layout.ry}deg) rotateX(${layout.rx}deg) rotate(${layout.rot}deg) scale(${layout.scale})`
}

/**
 * Debounces fn: rapid calls collapse into one, `waitMs` after the last call.
 * `.flush(...args)` runs immediately and cancels the pending timer.
 * `.cancel()` cancels without calling.
 */
export function debounce(fn, waitMs) {
  let timer = null

  function debounced(...args) {
    clearTimeout(timer)
    timer = setTimeout(() => { timer = null; fn(...args) }, waitMs)
  }

  debounced.flush = (...args) => {
    clearTimeout(timer)
    timer = null
    fn(...args)
  }

  debounced.cancel = () => {
    clearTimeout(timer)
    timer = null
  }

  return debounced
}
