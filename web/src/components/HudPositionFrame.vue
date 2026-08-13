<template>
  <div
    v-show="entry.visible"
    class="absolute"
    :style="frameStyle"
    @pointerdown="onPointerDown"
  >
    <component :is="entry.component" />
  </div>
</template>

<script setup>
import { computed, inject } from 'vue'
import Obelisk from '@/obelisk.js'
import { layoutTransform, debounce } from '@/lib/hudLayout.js'

const props = defineProps({
  name: { type: String, required: true },
  entry: { type: Object, required: true },
})

const editMode = inject('obelisk:hudEditMode')
const selection = inject('obelisk:hudEditSelection')
const editScope = inject('obelisk:hudEditScope')
const canvasScale = inject('obelisk:hudCanvasScale')

const selected = computed(() => editMode.value && selection.value === props.name)

const frameStyle = computed(() => ({
  left: props.entry.layout.x + 'px',
  top: props.entry.layout.y + 'px',
  width: props.entry.layout.width + 'px',
  textAlign: props.entry.layout.align || 'left',
  transformOrigin: 'top left',
  transform: layoutTransform(props.entry.layout),
  cursor: editMode.value ? 'move' : 'default',
  outline: !editMode.value
    ? 'none'
    : (selected.value ? '1px dashed color-mix(in oklab, var(--ob-accent) 70%, transparent)' : '1px dashed rgba(255,255,255,.18)'),
  outlineOffset: '6px',
  zIndex: selected.value ? 40 : undefined,
}))

const persistLayout = debounce(() => {
  const l = props.entry.layout
  Obelisk.emit('oblsk_preferences:client:set', {
    scope: editScope.value,
    key: `hud:${props.name}:layout`,
    value: { x: l.x, y: l.y, scale: l.scale, rx: l.rx, ry: l.ry, rot: l.rot },
  })
}, 400)

let drag = null

function onPointerDown(ev) {
  if (!editMode.value) return
  ev.stopPropagation()
  selection.value = props.name
  drag = { x0: props.entry.layout.x, y0: props.entry.layout.y, px: ev.clientX, py: ev.clientY }
  window.addEventListener('pointermove', onPointerMove)
  window.addEventListener('pointerup', onPointerUp)
}

function onPointerMove(ev) {
  if (!drag) return
  const k = canvasScale.value || 1
  props.entry.layout.x = Math.round(drag.x0 + (ev.clientX - drag.px) / k)
  props.entry.layout.y = Math.round(drag.y0 + (ev.clientY - drag.py) / k)
  persistLayout()
}

function onPointerUp() {
  if (!drag) return
  drag = null
  persistLayout.flush()
  window.removeEventListener('pointermove', onPointerMove)
  window.removeEventListener('pointerup', onPointerUp)
}
</script>
