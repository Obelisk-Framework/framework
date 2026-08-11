<template>
  <div class="absolute inset-0 flex items-start justify-end pr-4 pt-6 pointer-events-none">
    <div class="w-[340px] select-none pointer-events-auto" style="--ob-accent:#10b981">
      <!-- banner -->
      <div class="h-[76px] rounded-t-lg grid place-items-center relative overflow-hidden" style="background:var(--ob-accent)">
        <div class="absolute inset-0 opacity-20" style="background-image:repeating-linear-gradient(45deg, rgba(0,0,0,.4) 0 8px, transparent 8px 16px)" />
        <div class="relative text-center">
          <div class="text-[24px] font-bold tracking-[0.1em] text-black">{{ cur.title }}</div>
        </div>
      </div>

      <!-- subtitle bar -->
      <div class="h-9 bg-black/90 px-4 flex items-center justify-between">
        <span class="ob-mono text-[11px] tracking-[0.15em] text-white/85">{{ cur.sub }}</span>
        <span class="ob-mono text-[11px] text-white/45">{{ items.length ? idx + 1 : 0 }} / {{ items.length }}</span>
      </div>

      <!-- breadcrumb -->
      <div v-if="stack.length > 1" class="h-7 bg-black/70 px-4 flex items-center gap-1.5 ob-mono text-[9.5px] text-white/35">
        <template v-for="(s, i) in stack" :key="i">
          <span v-if="i > 0" class="text-white/20">&rsaquo;</span>
          <button
            @click="jumpTo(i)"
            :class="i === stack.length - 1 ? 'text-white/70' : 'hover:text-white/70'"
          >{{ s.title }}</button>
        </template>
      </div>

      <!-- items -->
      <div class="bg-black/80">
        <div
          v-for="(it, i) in items"
          :key="it.key"
          @mouseenter="idx = i"
          @click="activate(it)"
          class="h-[38px] px-4 flex items-center gap-2 cursor-pointer"
          :style="{
            background: i === idx ? 'var(--ob-accent)' : 'transparent',
            color: i === idx ? '#000' : it.danger ? '#f87171' : 'rgba(255,255,255,.85)'
          }"
        >
          <span v-if="favourites.has(it.key)" class="text-[11px]" :style="{ color: i === idx ? '#000' : 'var(--ob-accent)' }">&#9733;</span>
          <span class="text-[13.5px] flex-1 truncate">{{ it.label }}</span>

          <span v-if="it.type === 'menu'" class="text-[15px] opacity-70">&rsaquo;</span>
          <span v-else-if="(it.type === 'action' || it.type === 'list') && it.right" class="ob-mono text-[10px] opacity-65">{{ it.right }}</span>

          <span v-else-if="it.type === 'check'" class="w-4 h-4 rounded-sm border grid place-items-center"
            :style="{ borderColor: i === idx ? 'rgba(0,0,0,.5)' : 'rgba(255,255,255,.4)', background: it.value ? (i === idx ? '#000' : 'var(--ob-accent)') : 'transparent' }">
            <svg v-if="it.value" width="11" height="11" viewBox="0 0 16 16" :fill="i === idx ? 'var(--ob-accent)' : '#000'">
              <path d="M13.5 3.5 6 11l-3.5-3.5-1 1L6 13l8.5-8.5z" />
            </svg>
          </span>

          <span v-else-if="it.type === 'select'" class="flex items-center gap-1.5 ob-mono text-[11px]">
            <span class="opacity-50">&lsaquo;</span>{{ it.value }}<span class="opacity-50">&rsaquo;</span>
          </span>

          <span v-else-if="it.type === 'slider'" class="flex items-center gap-2">
            <span class="relative w-24 h-1.5 rounded-full" :style="{ background: i === idx ? 'rgba(0,0,0,.25)' : 'rgba(255,255,255,.15)' }">
              <span class="absolute inset-y-0 left-0 rounded-full" :style="{ width: sliderPct(it) + '%', background: i === idx ? '#000' : 'var(--ob-accent)' }" />
            </span>
            <span class="ob-mono text-[10.5px] w-9 text-right">{{ it.value }}{{ it.unit }}</span>
          </span>

          <span v-else-if="it.type === 'range'" class="flex items-center gap-1.5">
            <span v-for="(o, n) in it.options" :key="o" class="w-2.5 h-2.5 rounded-full"
              :style="{ background: n === it.value ? (i === idx ? '#000' : 'var(--ob-accent)') : i === idx ? 'rgba(0,0,0,.25)' : 'rgba(255,255,255,.18)' }" />
            <span class="ob-mono text-[10.5px] ml-1">{{ it.options[it.value] }}</span>
          </span>

          <span v-else-if="it.type === 'text'">
            <input
              v-if="editing === it.key"
              autofocus
              v-model="it.value"
              @blur="editing = null"
              @keydown.enter.stop.prevent="editing = null"
              @keydown.escape.stop.prevent="editing = null"
              class="w-28 h-6 px-2 rounded bg-black/60 border border-white/25 ob-mono text-[11px] text-white outline-none"
              @click.stop
            />
            <span v-else class="ob-mono text-[11px] opacity-65">{{ it.value }}</span>
          </span>
        </div>
      </div>

      <!-- description bar -->
      <div v-if="item && item.desc" class="bg-black/90 border-t border-white/10 px-4 py-2.5">
        <p class="text-[11.5px] text-white/55 leading-snug">{{ item.desc }}</p>
      </div>

      <!-- footer -->
      <div class="h-8 bg-black/95 rounded-b-lg px-4 flex items-center justify-between ob-mono text-[9px] text-white/35">
        <span>&uarr;&darr; NAVIGATE &middot; &larr;&rarr; ADJUST &middot; F FAVOURITE</span>
        <span>ENTER SELECT</span>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'

/**
 * Self-contained layered menu. `root` is { title, sub, items }, where items
 * of type 'menu' nest their own submenu directly under `items` rather than
 * an id lookup table, so callers (Lua/NUI or plain Vue) can hand this a
 * plain tree with no shared registry.
 */
const props = defineProps({
  root: { type: Object, required: true }
})

const emit = defineEmits(['action', 'change', 'close', 'favorite-toggle'])

const stack = ref([props.root])
const idx = ref(0)
const editing = ref(null)
const favourites = ref(new Set(collectInitialFavourites(props.root)))

function collectInitialFavourites(node, out = new Set()) {
  for (const it of node.items || []) {
    if (it.favorite) out.add(it.key)
    if (it.items) collectInitialFavourites(it, out)
  }
  return out
}

const cur = computed(() => stack.value[stack.value.length - 1])
const items = computed(() => cur.value.items || [])
const item = computed(() => items.value[idx.value])

function sliderPct(it) {
  return ((it.value - it.min) / (it.max - it.min)) * 100
}

function jumpTo(i) {
  stack.value = stack.value.slice(0, i + 1)
  idx.value = 0
}

function openSubmenu(it) {
  stack.value = [...stack.value, { title: it.label.toUpperCase(), sub: cur.value.title, items: it.items || [] }]
  idx.value = 0
}

function activate(it) {
  if (it.type === 'menu') {
    openSubmenu(it)
  } else if (it.type === 'check') {
    it.value = !it.value
    emit('change', it)
  } else if (it.type === 'text') {
    editing.value = it.key
  } else if (it.type === 'action' || it.type === 'list') {
    emit('action', it)
  }
}

function adjust(dir) {
  const it = item.value
  if (!it) return
  if (it.type === 'slider') {
    it.value = Math.max(it.min, Math.min(it.max, it.value + dir * 5))
    emit('change', it)
  } else if (it.type === 'select') {
    const n = (it.options.indexOf(it.value) + dir + it.options.length) % it.options.length
    it.value = it.options[n]
    emit('change', it)
  } else if (it.type === 'range') {
    it.value = Math.max(0, Math.min(it.options.length - 1, it.value + dir))
    emit('change', it)
  }
}

function toggleFavourite(it) {
  if (favourites.value.has(it.key)) favourites.value.delete(it.key)
  else favourites.value.add(it.key)
  favourites.value = new Set(favourites.value)
  emit('favorite-toggle', it, favourites.value.has(it.key))
}

function onKeydown(e) {
  if (editing.value) return
  if (e.key === 'ArrowDown') { e.preventDefault(); idx.value = items.value.length ? (idx.value + 1) % items.value.length : 0 }
  else if (e.key === 'ArrowUp') { e.preventDefault(); idx.value = items.value.length ? (idx.value - 1 + items.value.length) % items.value.length : 0 }
  else if (e.key === 'ArrowRight') { e.preventDefault(); adjust(1) }
  else if (e.key === 'ArrowLeft') { e.preventDefault(); adjust(-1) }
  else if (e.key === 'Enter') { e.preventDefault(); if (item.value) activate(item.value) }
  else if (e.key === 'Backspace') {
    if (stack.value.length > 1) { stack.value = stack.value.slice(0, -1); idx.value = 0 }
    else emit('close')
  } else if (e.key === 'f' || e.key === 'F') {
    if (item.value) toggleFavourite(item.value)
  } else if (e.key === 'Escape') {
    emit('close')
  }
}

onMounted(() => window.addEventListener('keydown', onKeydown))
onBeforeUnmount(() => window.removeEventListener('keydown', onKeydown))
</script>

<style scoped>
.ob-mono {
  font-family: 'JetBrains Mono', ui-monospace, monospace;
}
</style>
