<template>
  <div class="fixed bottom-20 left-1/2 -translate-x-1/2 z-50 space-y-3 w-96">
    <TransitionGroup name="progress">
      <div
        v-for="progress in progressBars"
        :key="progress.id"
        class="bg-gray-800/90 backdrop-blur-sm rounded-lg shadow-lg p-4"
      >
        <div class="flex items-center justify-between mb-2">
          <span class="text-white text-sm font-medium">{{ progress.label }}</span>
          <button
            v-if="progress.canCancel"
            @click="cancel(progress.id)"
            class="text-red-400 hover:text-red-300 transition-colors"
          >
            <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 20 20">
              <path fill-rule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clip-rule="evenodd" />
            </svg>
          </button>
        </div>
        
        <!-- Progress bar -->
        <div class="w-full bg-gray-700 rounded-full h-2.5 overflow-hidden">
          <div
            class="bg-blue-500 h-full transition-all duration-100 ease-linear"
            :style="{ width: `${progress.percent}%` }"
          ></div>
        </div>
        
        <!-- Time remaining -->
        <div class="mt-1 text-right text-xs text-gray-400">
          {{ formatTime(progress.remaining) }}
        </div>
      </div>
    </TransitionGroup>
  </div>
</template>

<script setup>
import { ref, onMounted, onUnmounted } from 'vue'

const progressBars = ref([])
let updateInterval = null

// Add progress bar
const addProgress = (progress) => {
  progress.startTime = Date.now()
  progress.percent = 0
  progress.remaining = progress.duration
  
  progressBars.value.push(progress)
}

// Update progress percentages
const updateProgress = () => {
  const now = Date.now()
  
  progressBars.value.forEach(progress => {
    const elapsed = now - progress.startTime
    progress.percent = Math.min(100, (elapsed / progress.duration) * 100)
    progress.remaining = Math.max(0, progress.duration - elapsed)
    
    // Auto-complete when duration reached
    if (progress.percent >= 100) {
      complete(progress.id)
    }
  })
}

// Complete progress bar
const complete = (progressId) => {
  const index = progressBars.value.findIndex(p => p.id === progressId)
  if (index !== -1) {
    progressBars.value.splice(index, 1)
    
    // Notify Lua
    if (window.invokeNative) {
      fetch(`https://${GetParentResourceName()}/core:client:progress-completed`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ progressId })
      })
    }
  }
}

// Cancel progress bar
const cancel = (progressId) => {
  const index = progressBars.value.findIndex(p => p.id === progressId)
  if (index !== -1) {
    progressBars.value.splice(index, 1)
    
    // Notify Lua
    if (window.invokeNative) {
      fetch(`https://${GetParentResourceName()}/core:client:progress-userCancel`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ progressId })
      })
    }
  }
}

// Format time in seconds
const formatTime = (ms) => {
  const seconds = Math.ceil(ms / 1000)
  return `${seconds}s`
}

// Listen for messages from Lua
onMounted(() => {
  window.addEventListener('message', handleMessage)
  
  // Start update interval
  updateInterval = setInterval(updateProgress, 100)
})

onUnmounted(() => {
  window.removeEventListener('message', handleMessage)
  
  if (updateInterval) {
    clearInterval(updateInterval)
  }
})

const handleMessage = (event) => {
  const data = event.data
  
  if (data.type === 'core:client:progress-start') {
    addProgress(data.progress)
  } else if (data.type === 'core:client:progress-complete') {
    complete(data.progressId)
  } else if (data.type === 'core:client:progress-cancel') {
    const index = progressBars.value.findIndex(p => p.id === data.progressId)
    if (index !== -1) {
      progressBars.value.splice(index, 1)
    }
  }
}

// Helper to get resource name
function GetParentResourceName() {
  let currentUrl = window.location.href
  let match = currentUrl.match(/https?:\/\/(.*?)\//)
  return match ? match[1] : 'obelisk'
}
</script>

<style scoped>
.progress-enter-active,
.progress-leave-active {
  transition: all 0.3s ease;
}

.progress-enter-from {
  opacity: 0;
  transform: translateY(20px);
}

.progress-leave-to {
  opacity: 0;
  transform: translateY(-20px);
}
</style>
