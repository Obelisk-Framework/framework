import { computeCanvasFit, layoutTransform, debounce } from './hudLayout.js'

const tests = []
function test(name, fn) { tests.push({ name, fn }) }

function eq(actual, expected, msg) {
  if (actual !== expected) {
    throw new Error(`${msg || 'assertion failed'}\n     expected: ${expected}\n     actual:   ${actual}`)
  }
}

test('computeCanvasFit: 1920x1080 viewport gives scale 1, no offset', () => {
  const fit = computeCanvasFit(1920, 1080)
  eq(fit.scale, 1, 'scale')
  eq(fit.offsetX, 0, 'offsetX')
  eq(fit.offsetY, 0, 'offsetY')
})

test('computeCanvasFit: wider-than-16:9 viewport letterboxes left/right', () => {
  const fit = computeCanvasFit(2560, 1080)
  eq(fit.scale, 1, 'scale')
  eq(fit.offsetX, 320, 'offsetX')
  eq(fit.offsetY, 0, 'offsetY')
})

test('computeCanvasFit: taller-than-16:9 viewport letterboxes top/bottom', () => {
  const fit = computeCanvasFit(1920, 1440)
  eq(fit.scale, 1, 'scale')
  eq(fit.offsetY, 180, 'offsetY')
})

test('computeCanvasFit: smaller viewport scales down uniformly, capped by the tighter axis', () => {
  const fit = computeCanvasFit(960, 540)
  eq(fit.scale, 0.5, 'scale')
})

test('layoutTransform: builds the expected CSS transform string', () => {
  const css = layoutTransform({ scale: 1.2, rx: 5, ry: -10, rot: 3 })
  eq(css, 'perspective(1100px) rotateY(-10deg) rotateX(5deg) rotate(3deg) scale(1.2)', 'transform string')
})

test('debounce: collapses rapid calls into one, using the last call\'s args', async () => {
  const calls = []
  const debounced = debounce((v) => calls.push(v), 30)
  debounced(1); debounced(2); debounced(3)
  await new Promise((resolve) => setTimeout(resolve, 60))
  eq(calls.length, 1, 'call count')
  eq(calls[0], 3, 'last value')
})

test('debounce: flush() runs immediately with the pending args and skips the wait', () => {
  const calls = []
  const debounced = debounce((v) => calls.push(v), 1000)
  debounced('a')
  debounced.flush('a')
  eq(calls.length, 1, 'call count')
})

let passed = 0
const failures = []

for (const t of tests) {
  try {
    await t.fn()
    passed++
    console.log('  ok   - ' + t.name)
  } catch (err) {
    failures.push(t.name)
    console.log('  FAIL - ' + t.name)
    console.log('         ' + String(err.message || err).replaceAll('\n', '\n         '))
  }
}

console.log(`\n${passed} passed, ${failures.length} failed`)
process.exit(failures.length === 0 ? 0 : 1)
