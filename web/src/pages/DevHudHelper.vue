<template>
  <div class="min-h-screen text-white p-6 font-mono text-sm">
    <div class="max-w-md">
      <div class="text-xs tracking-[0.2em] uppercase text-white/40 mb-1">Obelisk · Dev only</div>
      <h1 class="text-lg font-semibold mb-4">HUD elements</h1>
      <div v-if="entries.length === 0" class="text-white/40">No global elements registered.</div>
      <label
        v-for="[name, entry] in entries"
        :key="name"
        class="flex items-center gap-3 py-1.5 cursor-pointer select-none hover:bg-white/5 rounded px-1.5 -mx-1.5"
      >
        <input type="checkbox" :checked="entry.visible" @change="toggle(name, entry, $event.target.checked)" />
        <span class="flex-1">{{ name }}</span>
        <span class="text-white/30 text-xs">{{ entry.visible ? 'visible' : 'hidden' }}</span>
      </label>

      <div class="mt-6 pt-4 border-t border-white/10">
        <div class="text-xs tracking-[0.2em] uppercase text-white/40 mb-2">Phone debug</div>
        <div class="flex flex-wrap gap-2 mb-3">
          <button class="px-3 py-1.5 rounded border border-white/15 hover:bg-white/10 text-xs" @click="toggleDock">Toggle phone dock</button>
          <button class="px-3 py-1.5 rounded border border-white/15 hover:bg-white/10 text-xs" @click="simulateCall">Simulate incoming call</button>
        </div>
        <div class="text-xs tracking-[0.2em] uppercase text-white/40 mb-2">Send a test notification</div>
        <div class="flex flex-wrap gap-2">
          <button
            v-for="bench in testBench"
            :key="bench.label"
            class="px-3 py-1.5 rounded border border-white/15 hover:bg-white/10 text-xs"
            @click="fireTestNotification(bench)"
          >{{ bench.label }}</button>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { inject, onMounted, computed } from 'vue'

const STORAGE_PREFIX = 'obelisk:dev-hud-helper:'

const registry = inject('obelisk:globalElementsRegistry')
const entries = computed(() => registry ? Array.from(registry.entries()) : [])

function toggle(name, entry, visible) {
  entry.visible = visible
  localStorage.setItem(STORAGE_PREFIX + name, visible ? '1' : '0')
}

onMounted(() => {
  if (!registry) return
  for (const [name, entry] of registry) {
    const stored = localStorage.getItem(STORAGE_PREFIX + name)
    if (stored !== null) entry.visible = stored === '1'
  }
})

const testBench = [
  { label: 'Dispatch', app: 'dispatch', title: 'Priority 1 · Shots fired', body: 'Forum Dr, Davis, two units required.' },
  { label: 'Mail', app: 'mail', title: 'Dana Kirsch', body: 'Discovery for LSPD-2026-114' },
  { label: 'Bank', app: 'banking', title: 'Payment received', body: 'Payroll · +$1,240.00' },
  { label: 'Message', app: 'messages', title: 'Marco Vance', body: 'Got the parts. Garage at 5?' },
  { label: 'Local', app: 'settings', net: false, title: 'Battery at 15%', body: 'Low power mode is available.' }
]

function postToPhone(eventname, payload) {
  window.postMessage({ eventname, args: [payload] }, '*')
}

function fireTestNotification(bench) {
  postToPhone('obelisk:dev-debug:notify', bench)
}

function toggleDock() {
  postToPhone('obelisk:dev-debug:toggle-phone-dock', {})
}

function simulateCall() {
  postToPhone('obelisk:dev-debug:simulate-call', {})
}
</script>
