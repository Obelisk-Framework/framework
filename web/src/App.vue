<template>
  <div id="app" class="relative">
    <component
      v-for="[name, entry] in registry"
      :key="name"
      :is="entry.component"
      v-show="entry.visible"
    />
    <router-view />
  </div>
</template>

<script setup>
import { reactive, onMounted } from 'vue'
import router from './router'
import Obelisk from './obelisk.js'
import coreGlobalElements from './globalElements.js'

const pluginGlobalElementModules = import.meta.glob('../../plugins/*/web/globalElements.js', { eager: true })

const pluginGlobalElements = []
for (const mod of Object.values(pluginGlobalElementModules)) {
  if (Array.isArray(mod.default)) {
    pluginGlobalElements.push(...mod.default)
  } else {
    console.warn('[Obelisk] a plugin globalElements.js did not export a default array, skipping')
  }
}

const registry = reactive(new Map())
for (const entry of [...coreGlobalElements, ...pluginGlobalElements]) {
  if (!entry || !entry.name || !entry.component) {
    console.warn('[Obelisk] a global element entry is missing name/component, skipping', entry)
    continue
  }
  const defaultVisible = !!entry.defaultVisible
  registry.set(entry.name, { component: entry.component, defaultVisible, visible: defaultVisible })
}

onMounted(() => {
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
  })
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
