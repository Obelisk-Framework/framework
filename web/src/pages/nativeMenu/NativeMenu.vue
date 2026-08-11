<template>
  <NativeMenuKit
    v-if="menu"
    :root="menu"
    @action="onAction"
    @change="onChange"
    @favorite-toggle="onFavoriteToggle"
    @close="onClose"
  />
</template>

<script setup>
import { ref, onMounted, onBeforeUnmount } from 'vue'
import NativeMenuKit from './NativeMenuKit.vue'
import Obelisk from '../../obelisk.js'
import { demoMenu } from './demoMenu.js'

const menu = ref(import.meta.env.DEV ? demoMenu() : null)

function onOpen(tree) {
  menu.value = tree
}

function onAction(item) {
  Obelisk.emit('nativeMenu:action', [item.key])
}

function onChange(item) {
  Obelisk.emit('nativeMenu:change', [item.key, item.value])
}

function onFavoriteToggle(item, isFavorite) {
  Obelisk.emit('nativeMenu:favoriteToggle', [item.key, isFavorite])
}

function onClose() {
  menu.value = null
  Obelisk.emit('core:client:close')
}

onMounted(() => {
  Obelisk.on('core:client:nativeMenu-open', onOpen)
})

onBeforeUnmount(() => {
  Obelisk.off('core:client:nativeMenu-open', onOpen)
})
</script>
