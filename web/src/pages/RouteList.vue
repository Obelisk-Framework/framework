<template>
  <div class="min-h-screen text-black p-6 font-mono text-sm">
    <div class="max-w-2xl">
      <div class="text-xs tracking-[0.2em] uppercase text-black/50 mb-1">Obelisk · Dev only</div>
      <h1 class="text-lg font-semibold mb-4">Registered routes · {{ routes.length }}</h1>

      <a
        v-for="route in routes"
        :key="route.path"
        :href="route.path"
        target="_blank"
        rel="noopener"
        class="flex items-center gap-3 py-1.5 border-b border-black/10 hover:bg-black/5 -mx-1.5 px-1.5 rounded"
      >
        <span class="flex-1 truncate">{{ route.path }}</span>
        <span class="text-black/40 text-xs">{{ route.name }}</span>
        <span class="text-black/40 text-xs w-40 shrink-0 text-right truncate">{{ route.source }}</span>
      </a>
    </div>
  </div>
</template>

<script setup>
import { computed } from 'vue'
import router from '../router'

const routeModules = import.meta.glob(
  ['../../../modules/*/web/routes.js', '../../../plugins/*/web/routes.js'],
  { eager: true }
)

function sourceForPath(path) {
  for (const [file, mod] of Object.entries(routeModules)) {
    if (Array.isArray(mod.default) && mod.default.some(r => r.path === path)) {
      const match = file.match(/(modules|plugins)\/([^/]+)\/web\/routes\.js$/)
      return match ? match[2] : 'plugin'
    }
  }
  return 'core'
}

const EXCLUDED_PATHS = ['/character-selection']

const routes = computed(() =>
  router.getRoutes()
    .filter(r => !EXCLUDED_PATHS.includes(r.path))
    .map(r => ({ path: r.path, name: r.name, source: sourceForPath(r.path) }))
    .sort((a, b) => a.path.localeCompare(b.path))
)
</script>
