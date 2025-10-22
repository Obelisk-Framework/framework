<template>
  <div class="fixed top-4 right-4 z-50 space-y-3 w-96">
    <TransitionGroup name="notification">
      <div
        v-for="notification in notifications"
        :key="notification.id"
        :class="['rounded-lg shadow-lg p-4 backdrop-blur-sm', getTypeClasses(notification.type)]"
      >
        <div class="flex items-start">
          <div class="flex-shrink-0">
            <component :is="getIcon(notification.type)" class="w-6 h-6" />
          </div>
          <div class="ml-3 flex-1">
            <h3 class="text-sm font-medium">{{ notification.title }}</h3>
            <p v-if="notification.description" class="mt-1 text-sm opacity-90">
              {{ notification.description }}
            </p>
          </div>
          <button @click="dismiss(notification.id)" class="ml-4 flex-shrink-0">
            <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 20 20">
              <path fill-rule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clip-rule="evenodd" />
            </svg>
          </button>
        </div>
      </div>
    </TransitionGroup>
  </div>
</template>

<script setup>
import { ref, onMounted } from 'vue'

const notifications = ref([])

// Type-specific styling
const getTypeClasses = (type) => {
  const classes = {
    success: 'bg-green-500/90 text-white',
    error: 'bg-red-500/90 text-white',
    danger: 'bg-red-500/90 text-white',
    warning: 'bg-yellow-500/90 text-white',
    info: 'bg-blue-500/90 text-white',
    default: 'bg-gray-800/90 text-white'
  }
  return classes[type] || classes.default
}

// Get icon component for type
const getIcon = (type) => {
  // Using inline SVG for simplicity - in production use icon library
  if (type === 'success') return 'svg'
  if (type === 'error' || type === 'danger') return 'svg'
  if (type === 'warning') return 'svg'
  if (type === 'info') return 'svg'
  return 'svg'
}

// Add notification to queue
const addNotification = (notification) => {
  notifications.value.push(notification)
  
  // Auto-dismiss after duration
  const duration = notification.duration || 5000
  setTimeout(() => {
    dismiss(notification.id)
  }, duration)
}

// Dismiss notification
const dismiss = (id) => {
  const index = notifications.value.findIndex(n => n.id === id)
  if (index !== -1) {
    notifications.value.splice(index, 1)
    
    // Notify client Lua
    if (window.invokeNative) {
      fetch(`https://${GetParentResourceName()}/notification:dismissed`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id })
      })
    }
  }
}

// Listen for messages from Lua
onMounted(() => {
  window.addEventListener('message', (event) => {
    const data = event.data
    
    if (data.type === 'notification:show') {
      addNotification(data.notification)
    }
  })
})

// Helper to get resource name
function GetParentResourceName() {
  let currentUrl = window.location.href
  let match = currentUrl.match(/https?:\/\/(.*?)\//)
  return match ? match[1] : 'obelisk'
}
</script>

<style scoped>
.notification-enter-active,
.notification-leave-active {
  transition: all 0.3s ease;
}

.notification-enter-from {
  opacity: 0;
  transform: translateX(100px);
}

.notification-leave-to {
  opacity: 0;
  transform: translateX(100px);
}
</style>
