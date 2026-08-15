<!-- core/plugins/oblsk_barber/web/BarberClipperGame.vue -->
<!-- Clipper-precision minigame — ported from the Claude Design reference's
     BbClipperGame (src/proto/barber-game.jsx): three clipper passes, a
     marker sweeping a guide bar that the player must stop inside a shrinking
     target band. The mean of the three pass scores maps onto a quality
     grade (bbGrade) whose `mult` discounts the price Barber.vue charges.
     `useState` -> `ref`, the JSX requestAnimationFrame loop -> an
     onMounted-started RAF loop held in a ref and cancelled in
     onBeforeUnmount, the window keydown listener attached/detached the same
     way — same porting convention Task 7 used for Barber.vue. The `bb-d`
     custom font-utility class doesn't exist in this project's Tailwind
     config (per Task 7's own note) — replaced with plain Tailwind utility
     classes (`font-semibold uppercase tracking-wide`), matching what
     Task 7 did in Barber.vue. -->
<template>
  <div class="absolute inset-0 z-50 grid place-items-center" style="background:rgba(0,0,0,.72)">
    <div class="rounded-[12px] overflow-hidden" style="width:520px;background:rgba(9,12,12,.95);border:1px solid rgba(255,255,255,.12)">
      <div class="px-4 h-[46px] flex items-center gap-2" style="border-bottom:1px solid rgba(255,255,255,.08);background:rgba(255,255,255,.03)">
        <span class="font-semibold uppercase tracking-wide text-[13px]">{{ label }}</span>
        <span class="ob-mono text-[11px] text-white/35 ml-auto">
          {{ result ? 'DONE' : `PASS ${Math.min(pass + 1, BB_PASSES.length)} / ${BB_PASSES.length} · ${BB_PASSES[Math.min(pass, 2)][0]}` }}
        </span>
      </div>

      <div class="p-4">
        <!-- the guide -->
        <div class="relative rounded-[8px] p-5" style="background:linear-gradient(160deg,#161a18,#0e1110);border:1px solid rgba(255,255,255,.09)">
          <div class="relative h-[54px] rounded-[6px] overflow-hidden"
            style="background:rgba(255,255,255,.05);border:1px solid rgba(255,255,255,.1)">
            <!-- target band -->
            <div class="absolute inset-y-0" :style="{
              left: `${(target - width / 2) * 100}%`, width: `${width * 100}%`,
              background: 'color-mix(in oklab, var(--ob-accent) 26%, transparent)',
              borderLeft: '1px solid var(--ob-accent)', borderRight: '1px solid var(--ob-accent)',
            }" />
            <div class="absolute inset-y-0 w-[2px]" :style="{ left: `${target * 100}%`, background: 'var(--ob-accent)' }" />
            <!-- clipper marker -->
            <div class="absolute inset-y-0 w-[3px]" :style="{ left: `${(locked ? locked.x : x) * 100}%`, background: locked ? (locked.score > 55 ? 'var(--ob-accent)' : '#ef4444') : '#fff' }" />
          </div>
          <div class="flex items-center justify-between mt-3">
            <div class="flex gap-1.5">
              <span v-for="(p, i) in BB_PASSES" :key="p[0]" class="ob-mono text-[10px] px-2 h-[22px] flex items-center rounded-[4px]"
                :style="{
                  background: scores[i] != null ? (scores[i] > 55 ? 'color-mix(in oklab, var(--ob-accent) 22%, transparent)' : 'rgba(239,68,68,.2)') : 'rgba(255,255,255,.05)',
                  border: `1px solid ${i === pass && !result ? 'rgba(255,255,255,.4)' : 'rgba(255,255,255,.12)'}`,
                  color: scores[i] != null ? '#fff' : 'rgba(255,255,255,.4)',
                }">{{ p[0] }}{{ scores[i] != null ? ` ${scores[i]}%` : '' }}</span>
            </div>
            <span v-if="locked" class="font-semibold uppercase tracking-wide text-[15px]" :style="{ color: locked.score > 55 ? 'var(--ob-accent)' : '#ef4444' }">{{ locked.score }}%</span>
          </div>
        </div>

        <div v-if="result" class="mt-4 rounded-[8px] p-4 text-center" style="background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.1)">
          <div class="font-semibold uppercase tracking-wide text-[22px]" :style="{ color: result.q >= 70 ? 'var(--ob-accent)' : '#f59e0b' }">{{ grade }}</div>
          <div class="text-[12.5px] text-white/55 mt-1">{{ blurb }}</div>
          <div class="ob-mono text-[11px] text-white/35 mt-2">QUALITY {{ result.q }}%</div>
          <div class="flex gap-2 mt-4">
            <button @click="retry" class="flex-1 h-[40px] rounded-[6px] font-semibold uppercase tracking-wide text-[12.5px] transition hover:bg-white/[0.08]"
              style="border:1px solid rgba(255,255,255,.14);color:rgba(255,255,255,.75)">Run it again</button>
            <button @click="finish"
              class="flex-1 h-[40px] rounded-[6px] font-semibold uppercase tracking-wide text-[12.5px] transition hover:brightness-110"
              style="background:var(--ob-accent);color:#04120d">
              {{ free ? 'Keep it' : `Keep it · €${Math.round(price * mult).toLocaleString()}` }}
            </button>
          </div>
        </div>
        <div v-else class="flex gap-2 mt-3">
          <button @click="$emit('cancel')" class="h-[40px] px-4 rounded-[6px] font-semibold uppercase tracking-wide text-[12.5px] transition hover:bg-white/[0.08]"
            style="border:1px solid rgba(255,255,255,.14);color:rgba(255,255,255,.7)">Cancel</button>
          <button @click="lock" :disabled="!running"
            class="flex-1 h-[40px] rounded-[6px] font-semibold uppercase tracking-wide text-[13px] disabled:opacity-40 transition hover:brightness-110"
            style="background:var(--ob-accent);color:#04120d">Stop the clipper · space</button>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'

const props = defineProps({
  label: { type: String, required: true },
  price: { type: Number, required: true },
  free: { type: Boolean, default: false },
})
const emit = defineEmits(['done', 'cancel'])

// Three clipper passes. Band width shrinks with each pass.
const BB_PASSES = [
  ['NAPE', 0.30], ['SIDES', 0.22], ['TOP LINE', 0.16],
]

function bbGrade(q) {
  return q >= 88 ? ['SHARP', 'Lines you could set a watch to.', 1] :
    q >= 70 ? ['TIDY', 'Clean enough for anyone.', 1] :
    q >= 48 ? ['UNEVEN', 'One side is winning.', 0.7] :
      ['BUTCHERED', 'Wear a hat for two weeks.', 0.45]
}

const pass = ref(0)
const scores = ref([])
const x = ref(0)
const dir = ref(1)
const running = ref(true)
const locked = ref(null)
const result = ref(null)
const target = ref(0.5)

const width = computed(() => BB_PASSES[Math.min(pass.value, BB_PASSES.length - 1)][1])
const speed = computed(() => 0.85 + pass.value * 0.35)

const [grade, blurb, mult] = [ref(null), ref(null), ref(1)]
watch(result, (r) => {
  if (!r) { grade.value = null; blurb.value = null; mult.value = 1; return }
  const [g, b, m] = bbGrade(r.q)
  grade.value = g; blurb.value = b; mult.value = m
})

// --- RAF sweep loop --------------------------------------------------------
const raf = ref(0)
let last = 0

function startLoop() {
  cancelAnimationFrame(raf.value)
  last = performance.now()
  raf.value = requestAnimationFrame(tick)
}

function tick(t) {
  if (!running.value) return
  const dt = (t - last) / 1000
  last = t
  let n = x.value + dir.value * speed.value * dt
  if (n > 1) { n = 1; dir.value = -1 }
  if (n < 0) { n = 0; dir.value = 1 }
  x.value = n
  raf.value = requestAnimationFrame(tick)
}

watch(running, (r) => {
  if (r) startLoop()
  else cancelAnimationFrame(raf.value)
})

// New target band each pass, matching the JSX's per-pass useEffect.
watch(pass, () => {
  target.value = 0.24 + Math.random() * 0.52
}, { immediate: true })

function lock() {
  if (!running.value || result.value) return
  running.value = false
  const off = Math.abs(x.value - target.value)
  const half = width.value / 2
  const score = Math.max(0, Math.round(100 - (off / half) * 100))
  locked.value = { x: x.value, score }
  setTimeout(() => {
    const all = [...scores.value, score]
    scores.value = all
    if (all.length >= BB_PASSES.length) {
      const q = Math.round(all.reduce((a, b) => a + b, 0) / all.length)
      result.value = { q }
    } else {
      pass.value += 1
      locked.value = null
      x.value = 0
      dir.value = 1
      running.value = true
    }
  }, 750)
}

function retry() {
  pass.value = 0
  scores.value = []
  x.value = 0
  dir.value = 1
  locked.value = null
  result.value = null
  running.value = true
}

function finish() {
  emit('done', { q: result.value.q, grade: grade.value, mult: mult.value })
}

function onKeydown(e) {
  if (e.code === 'Space' || e.key === 'Enter') {
    e.preventDefault()
    lock()
  }
}

onMounted(() => {
  window.addEventListener('keydown', onKeydown)
  startLoop()
})

onBeforeUnmount(() => {
  window.removeEventListener('keydown', onKeydown)
  cancelAnimationFrame(raf.value)
})
</script>
