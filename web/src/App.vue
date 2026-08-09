<template>
  <div id="app" class="relative">
    <!-- Global components always mounted -->
    <Notifications />
    <ProgressBars />
    
    <!-- Route-based pages -->
    <router-view />
  </div>
</template>

<script setup>
import { onMounted } from 'vue'
import Notifications from './components/global/Notifications.vue'
import ProgressBars from './components/global/ProgressBars.vue'

// Listen for route changes from Lua
onMounted(() => {
  window.addEventListener('message', (event) => {
    const data = event.data
    
    if (data.type === 'core:client:navigate' && data.route) {
    }
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
