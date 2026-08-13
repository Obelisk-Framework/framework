<template>
  <div id="app" class="relative">
    <div class="absolute top-0 left-0" :style="canvasWrapperStyle">
      <HudPositionFrame
        v-for="[name, entry] in positionableEntries"
        :key="name"
        :name="name"
        :entry="entry"
      />
    </div>
    <div
      v-for="[name, entry] in nonPositionableEntries"
      :key="name"
      v-show="entry.visible"
    >
      <component :is="entry.component" />
    </div>
    <router-view />
  </div>
</template>

<script setup>
import { reactive, ref, computed, onMounted, onUnmounted, provide } from 'vue'
import router from './router'
import Obelisk from './obelisk.js'
import coreGlobalElements from './globalElements.js'
import HudPositionFrame from './components/HudPositionFrame.vue'
import { computeCanvasFit } from './lib/hudLayout.js'

const contributedGlobalElementModules = import.meta.glob(
  ['../../modules/*/web/globalElements.js', '../../plugins/*/web/globalElements.js'],
  { eager: true }
)

const contributedGlobalElements = []
for (const mod of Object.values(contributedGlobalElementModules)) {
  if (Array.isArray(mod.default)) {
    contributedGlobalElements.push(...mod.default)
  } else {
    console.warn('[Obelisk] a globalElements.js did not export a default array, skipping')
  }
}

const registry = reactive(new Map())
for (const entry of [...coreGlobalElements, ...contributedGlobalElements]) {
  if (!entry || !entry.name || !entry.component) {
    console.warn('[Obelisk] a global element entry is missing name/component, skipping', entry)
    continue
  }
  if (registry.has(entry.name)) {
    console.warn(`[Obelisk] duplicate global element name "${entry.name}", keeping the last one discovered`)
  }
  const defaultVisible = !!entry.defaultVisible
  const positionable = !!entry.positionable
  const defaultLayout = entry.defaultLayout || { x: 0, y: 0, width: 300, align: 'left' }
  registry.set(entry.name, {
    component: entry.component,
    defaultVisible,
    visible: defaultVisible,
    positionable,
    defaultLayout,
    layout: reactive({
      x: defaultLayout.x, y: defaultLayout.y, width: defaultLayout.width, align: defaultLayout.align,
      scale: 1, rx: 0, ry: 0, rot: 0,
    }),
  })
}

const positionableEntries = computed(() => [...registry].filter(([, entry]) => entry.positionable))
const nonPositionableEntries = computed(() => [...registry].filter(([, entry]) => !entry.positionable))

provide('obelisk:globalElementsRegistry', registry)

const paymentApi = reactive({ requestPayment: null })
provide('obelisk:payment', paymentApi)

const hudEditMode = ref(false)
const hudEditSelection = ref(null)
const hudEditScope = ref('account')
provide('obelisk:hudEditMode', hudEditMode)
provide('obelisk:hudEditSelection', hudEditSelection)
provide('obelisk:hudEditScope', hudEditScope)

const canvasFit = ref(computeCanvasFit(window.innerWidth, window.innerHeight))
const hudCanvasScale = computed(() => canvasFit.value.scale)
provide('obelisk:hudCanvasScale', hudCanvasScale)

function updateCanvasFit() {
  canvasFit.value = computeCanvasFit(window.innerWidth, window.innerHeight)
}

const canvasWrapperStyle = computed(() => ({
  transform: `translate(${canvasFit.value.offsetX}px, ${canvasFit.value.offsetY}px) scale(${canvasFit.value.scale})`,
  transformOrigin: 'top left',
  width: '1920px',
  height: '1080px',
}))

onMounted(() => {
  window.addEventListener('resize', updateCanvasFit)

  Obelisk.on('core:client:navigate', (route) => {
    router.push(route)
  })

  Obelisk.on('core:client:webview-openPage', (page) => {
    router.push(page)
  })

  Obelisk.on('core:client:webview-showGlobalElement', (name) => {
    const entry = registry.get(name)
    if (entry) entry.visible = true
  })

  Obelisk.on('core:client:webview-hideGlobalElement', (name) => {
    const entry = registry.get(name)
    if (entry) entry.visible = false
  })

  Obelisk.on('core:client:webview-toggleGlobalElement', (name) => {
    const entry = registry.get(name)
    if (entry) entry.visible = !entry.visible
  })

  Obelisk.on('core:client:webview-destroy', () => {
    for (const entry of registry.values()) entry.visible = entry.defaultVisible
    hudEditMode.value = false
  })

  Obelisk.on('core:client:webview-hide', () => {
    hudEditMode.value = false
  })

  Obelisk.on('oblsk_preferences:client:hud-edit-mode-toggled', () => {
    hudEditMode.value = !hudEditMode.value
  })
})

onUnmounted(() => {
  window.removeEventListener('resize', updateCanvasFit)
})
</script>

<style>
/* Global styles */
#app {
  font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
}
</style>
