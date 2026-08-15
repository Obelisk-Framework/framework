<!-- core/plugins/oblsk_shellbuilder/web/ShellEditor.vue -->
<!-- Bottom-dock shell editor — ported from the Claude Design reference's
     SbEditor (src/proto/shell-builder.jsx). Tool rail is filtered by
     `canBuild` (Construction/Style are staff-only; Decorate is the only
     tool an owner without build permission ever sees). The palette/tool
     rail render from the server's real oblsk_items-backed catalog, not a
     static list. Placement/removal round-trips through the server so
     budget and locked-piece checks (ShellObjectService, Task 4) are
     authoritative. -->
<template>
  <div v-if="shell" class="absolute inset-0">
    <div class="absolute left-6 top-5 flex items-center gap-2.5">
      <span class="text-[14px] font-semibold uppercase tracking-wide">{{ shell.name }}</span>
      <span class="text-[10px] text-white/35 font-mono">EDITOR</span>
    </div>

    <div v-if="!walking" class="absolute left-0 right-0 bottom-0 flex" style="height:268px;background:rgba(4,7,6,.97);border-top:1px solid color-mix(in oklab, var(--ob-accent) 30%, transparent)">
      <!-- tool rail -->
      <div class="shrink-0 flex flex-col items-center justify-center gap-3 px-3" style="width:74px;border-right:1px solid rgba(255,255,255,.07)">
        <button v-for="t in availableTools" :key="t" @click="tool = t"
          class="w-[46px] h-[46px] rounded-[9px] grid place-items-center text-[10px] uppercase"
          :style="tool === t ? { background: 'color-mix(in oklab, var(--ob-accent) 26%, transparent)', border: '1px solid var(--ob-accent)' } : { background: 'rgba(255,255,255,.04)', border: '1px solid rgba(255,255,255,.1)' }">
          {{ t[0] }}
        </button>
      </div>

      <!-- items -->
      <div class="flex-1 min-w-0 flex flex-col py-3 px-3.5">
        <div class="text-[11px] text-white/45 uppercase tracking-wide mb-2">{{ tool }} · {{ items.length }} items</div>
        <div class="flex-1 min-h-0 overflow-y-auto flex flex-wrap gap-2 content-start">
          <button v-for="entry in items" :key="entry.key" @click="selectedItem = entry.key"
            class="rounded-[7px] px-2.5 py-2 text-[10.5px] text-left"
            :style="selectedItem === entry.key ? { background: 'color-mix(in oklab, var(--ob-accent) 30%, transparent)', border: '1px solid var(--ob-accent)' } : { background: 'color-mix(in oklab, var(--ob-accent) 10%, transparent)', border: '1px solid rgba(255,255,255,.1)' }">
            <div>{{ entry.name }}</div>
            <div class="text-white/40">{{ entry.category }}</div>
          </button>
          <div v-if="items.length === 0" class="text-[11px] text-white/35">Nothing in this category</div>
        </div>
      </div>

      <!-- budget + controls -->
      <div class="shrink-0 flex flex-col items-center gap-2 py-3 px-3" style="width:220px;border-left:1px solid rgba(255,255,255,.07)">
        <div class="w-full h-[24px] rounded-full relative overflow-hidden" style="background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.12)">
          <span class="absolute inset-y-0 left-0" :style="{ width: budgetPct + '%', background: 'var(--ob-accent)', opacity: .75 }" />
          <span class="absolute inset-0 flex items-center justify-center text-[10.5px] font-mono">{{ objects.length }} / {{ shell.object_budget }}</span>
        </div>
        <div class="flex gap-2 mt-1">
          <button @click="wreck = !wreck" class="h-[34px] px-3 rounded-[7px] text-[11px] uppercase"
            :style="wreck ? { background: 'rgba(190,40,40,.35)', border: '1px solid #ef4444' } : { background: 'rgba(255,255,255,.04)', border: '1px solid rgba(255,255,255,.1)' }">
            Delete mode
          </button>
          <button @click="walking = true" class="h-[34px] px-3 rounded-[7px] text-[11px] uppercase"
            style="background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.1)">
            Walk preview
          </button>
        </div>
        <div v-if="canBuild" class="flex gap-2">
          <button @click="forceLocked = !forceLocked" class="h-[34px] px-3 rounded-[7px] text-[11px] uppercase"
            :style="forceLocked ? { background: 'color-mix(in oklab, var(--ob-accent) 30%, transparent)', border: '1px solid var(--ob-accent)' } : { background: 'rgba(255,255,255,.04)', border: '1px solid rgba(255,255,255,.1)' }">
            Lock placement
          </button>
        </div>
        <button v-if="selectedItem && !wreck" @click="startAim" class="h-[34px] px-3 rounded-[7px] text-[11px] uppercase"
          style="background:color-mix(in oklab, var(--ob-accent) 30%, transparent);border:1px solid var(--ob-accent)">
          Place (aim)
        </button>
        <button @click="exitEditor" class="mt-auto h-[36px] w-full rounded-[7px] text-[12px] uppercase"
          style="background:var(--ob-accent);color:#04120d">Save & exit</button>
      </div>
    </div>

    <button v-else @click="walking = false"
      class="absolute left-6 bottom-6 h-[38px] px-4 rounded-[7px] text-[12px] uppercase"
      style="background:var(--ob-accent);color:#04120d">
      Back to editor
    </button>
  </div>
</template>

<script setup>
import { ref, computed, watch, onUnmounted } from 'vue'
import Obelisk from '../../../web/src/obelisk.js'

const shell = ref(null)
const objects = ref([])
const catalogBuild = ref([])
const catalogStyle = ref([])
const catalogDecor = ref([])
const canBuild = ref(false)

const tool = ref('decor')
const selectedItem = ref(null)
const wreck = ref(false)
const walking = ref(false)
// Staff-only toggle: lets staff explicitly lock a piece placed through the
// Decorate tool too, so a "comes with interior, not removable" shell can be
// fully furnished rather than only ever locking Construction/Style pieces.
const forceLocked = ref(false)

const availableTools = computed(() => canBuild.value ? ['build', 'style', 'decor'] : ['decor'])

const items = computed(() => {
  if (tool.value === 'build') return catalogBuild.value
  if (tool.value === 'style') return catalogStyle.value
  return catalogDecor.value
})

const budgetPct = computed(() => shell.value ? Math.min(100, (objects.value.length / shell.value.object_budget) * 100) : 0)

// A staff editor placing from Construction/Style always locks the piece
// (structural, owner-immutable); an owner in the Decorate tool always
// places unlocked furniture they can later remove themselves.
const armLocked = computed(() => canBuild.value && (tool.value !== 'decor' || forceLocked.value))

function startAim() {
  Obelisk.emit('shellbuilder:startAim', {})
}

function exitEditor() {
  if (!shell.value) return
  Obelisk.emit('shellbuilder:exit', { shellId: shell.value.id })
}

// Named handler for editSync event to enable proper cleanup
const onEditSync = (payload) => {
  shell.value = payload.shell
  objects.value = payload.objects || []
  catalogBuild.value = payload.catalogBuild || []
  catalogStyle.value = payload.catalogStyle || []
  catalogDecor.value = payload.catalogDecor || []
  canBuild.value = payload.canBuild || false
}

// Named handler for objectPlaced event to enable proper cleanup
const onObjectPlaced = (object) => {
  objects.value.push(object)
}

// Named handler for objectRemoved event to enable proper cleanup
const onObjectRemoved = ({ objectId }) => {
  objects.value = objects.value.filter(o => o.id !== objectId)
}

// Named handler for exited event to enable proper cleanup
const onExited = () => {
  shell.value = null
  objects.value = []
}

Obelisk.on('shellbuilder:editSync', onEditSync)
Obelisk.on('shellbuilder:objectPlaced', onObjectPlaced)
Obelisk.on('shellbuilder:objectRemoved', onObjectRemoved)
Obelisk.on('shellbuilder:exited', onExited)

// Unregister listeners when component unmounts to prevent listener buildup
onUnmounted(() => {
  Obelisk.off('shellbuilder:editSync', onEditSync)
  Obelisk.off('shellbuilder:objectPlaced', onObjectPlaced)
  Obelisk.off('shellbuilder:objectRemoved', onObjectRemoved)
  Obelisk.off('shellbuilder:exited', onExited)
})

watch(availableTools, (tools) => {
  if (!tools.includes(tool.value)) tool.value = 'decor'
})

// Arms/disarms client/placement.lua's aim-mode raycast placement whenever
// the selected item changes. Re-armed (rather than just once on select) so
// a locked-state change (canBuild/tool/forceLocked) while an item stays
// selected is picked up on the next selection, matching place()'s old
// locked-flag derivation above.
watch(selectedItem, (itemKey) => {
  if (itemKey) {
    Obelisk.emit('shellbuilder:arm', { itemKey, locked: armLocked.value })
  } else {
    Obelisk.emit('shellbuilder:disarm', {})
  }
})

// Switching tools invalidates whatever was armed from the previous tool's
// catalog (and its locked-flag derivation), so disarm on every tool change.
watch(tool, () => {
  Obelisk.emit('shellbuilder:disarm', {})
})

watch(wreck, (enabled) => {
  Obelisk.emit('shellbuilder:wreck', { enabled })
})

watch(shell, (s) => {
  Obelisk.emit('shellbuilder:setShellId', { shellId: s?.id ?? null })
})
</script>
