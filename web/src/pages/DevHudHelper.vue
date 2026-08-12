<template>
  <div class="min-h-screen bg-black/90 text-white p-6 font-mono text-sm">
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
</script>
