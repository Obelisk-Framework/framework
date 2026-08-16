<!-- core/plugins/oblsk_reflexcheck/web/ReflexCheck.vue -->
<script setup>
import { ref, onMounted, onUnmounted, computed } from 'vue'
import Obelisk from '@/obelisk.js'

const R = 118, CX = 160, CY = 160

const zoneAngle = ref(0)
const needleSpeed = ref(230)
const zoneWidth = ref(34)
const requiredHits = ref(1)
const hits = ref(0)
const startedAtMs = ref(0)
const needleAngle = ref(0)
const flash = ref(null) // 'hit' | 'miss' | null
const done = ref(null) // 'passed' | 'failed' | null

let rafId = null

function tick() {
  const elapsed = performance.now() - startedAtMs.value
  needleAngle.value = ((elapsed / 1000) * needleSpeed.value) % 360
  rafId = requestAnimationFrame(tick)
}

function attempt() {
  if (done.value) return
  Obelisk.emit('reflexcheck:attempt', {})
}

function onKeydown(e) {
  if (e.code !== 'Space') return
  e.preventDefault()
  attempt()
}

onMounted(() => {
  window.addEventListener('keydown', onKeydown)
  rafId = requestAnimationFrame(tick)

  Obelisk.on('reflexcheck:zone', (payload) => {
    zoneAngle.value = payload.zoneAngle
    needleSpeed.value = payload.needleSpeed
    zoneWidth.value = payload.zoneWidth
    requiredHits.value = payload.requiredHits
    startedAtMs.value = performance.now()
  })

  Obelisk.on('reflexcheck:feedback', (payload) => {
    zoneAngle.value = payload.zoneAngle
    flash.value = payload.result
    if (payload.result === 'hit') hits.value += 1
    setTimeout(() => { flash.value = null }, 260)
  })

  Obelisk.on('reflexcheck:result', (payload) => {
    done.value = payload.passed ? 'passed' : 'failed'
    if (rafId) cancelAnimationFrame(rafId)
  })
})

onUnmounted(() => {
  window.removeEventListener('keydown', onKeydown)
  if (rafId) cancelAnimationFrame(rafId)
})

function pol(r, deg) {
  return [CX + r * Math.cos((deg - 90) * Math.PI / 180), CY + r * Math.sin((deg - 90) * Math.PI / 180)]
}

const zoneArc = computed(() => {
  const [x1, y1] = pol(R, zoneAngle.value)
  const [x2, y2] = pol(R, zoneAngle.value + zoneWidth.value)
  return `M ${x1} ${y1} A ${R} ${R} 0 ${zoneWidth.value > 180 ? 1 : 0} 1 ${x2} ${y2}`
})

const needleEnd = computed(() => pol(R + 6, needleAngle.value))
const ringColor = computed(() => flash.value === 'miss' ? '#ef4444' : 'var(--ob-accent)')
</script>

<template>
  <div class="select-none flex items-center justify-center h-screen" @click="attempt">
    <div class="relative">
      <svg width="320" height="320" viewBox="0 0 320 320">
        <circle :cx="CX" :cy="CY" :r="R" fill="rgba(0,0,0,.45)" stroke="rgba(255,255,255,.10)" stroke-width="14" />
        <path :d="zoneArc" fill="none" stroke="var(--ob-accent)" stroke-width="14" opacity="0.42" />
        <line :x1="CX" :y1="CY" :x2="needleEnd[0]" :y2="needleEnd[1]"
          :stroke="ringColor" stroke-width="3.5" stroke-linecap="round" />
        <circle :cx="CX" :cy="CY" r="9" fill="#0a0c0d" :stroke="ringColor" stroke-width="2" />
        <text :x="CX" :y="CY - 8" text-anchor="middle" class="ob-mono" font-size="24" fill="#e6e8ea">{{ hits }}/{{ requiredHits }}</text>
      </svg>

      <div v-if="flash" class="absolute inset-0 grid place-items-center pointer-events-none">
        <div class="ob-mono text-[13px] font-semibold tracking-[0.24em] px-3 py-1 rounded-md"
          :style="{ transform: 'translateY(78px)', color: flash === 'miss' ? '#ef4444' : 'var(--ob-accent)', background: 'rgba(0,0,0,.5)' }">
          {{ flash === 'miss' ? 'MISS' : 'HIT' }}
        </div>
      </div>

      <div v-if="done" class="absolute inset-0 grid place-items-center rounded-full" style="background: rgba(5,7,8,.82)">
        <div class="text-center">
          <div class="ob-mono text-[15px] font-semibold" :style="{ color: done === 'passed' ? 'var(--ob-accent)' : '#ef4444' }">
            {{ done === 'passed' ? 'SUCCESS' : 'FAILED' }}
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
