<!-- core/plugins/oblsk_shellbuilder/web/ShellBrowser.vue -->
<!-- Shell browser — ported from the Claude Design reference's SbBrowser
     (src/proto/shell-browser.jsx): a shell list on the left, detail +
     actions on the right. Trimmed to what the signed-in player can
     actually do: owners get Enter, build-permission staff also get Edit
     and Create. -->
<template>
  <div class="absolute inset-0 grid place-items-center">
    <div class="rounded-[14px] overflow-hidden flex flex-col"
      style="width:1180px;height:780px;background:color-mix(in oklab, var(--ob-accent) 5%, rgba(8,11,10,.94));border:1px solid color-mix(in oklab, var(--ob-accent) 35%, transparent)">
      <div class="shrink-0 text-center pt-5 pb-4">
        <div class="text-[20px] font-semibold uppercase tracking-wide">Shell Creator</div>
        <div class="text-[11.5px] text-white/40 mt-0.5">interiors for housing, businesses and hideouts</div>
      </div>

      <div class="flex-1 min-h-0 flex gap-4 px-5">
        <!-- list -->
        <div class="flex-1 min-w-0 flex flex-col gap-2.5 overflow-y-auto pr-1"
          style="border-right:1px solid color-mix(in oklab, var(--ob-accent) 30%, transparent)">
          <button v-if="permissions.canBuild" @click="creating = true"
            class="shrink-0 h-[76px] rounded-[9px] text-[14px] font-semibold uppercase tracking-wide flex items-center justify-center gap-2"
            style="background:color-mix(in oklab, var(--ob-accent) 14%, transparent);border:1px dashed color-mix(in oklab, var(--ob-accent) 55%, transparent);color:#fff">
            Create new shell +
          </button>

          <button v-for="shell in shells" :key="shell.id" @click="selectedId = shell.id"
            class="shrink-0 rounded-[9px] p-3 flex items-start gap-3 text-left"
            :style="rowStyle(shell.id)">
            <span class="min-w-0 flex-1">
              <span class="block text-[15px] font-semibold uppercase tracking-wide leading-tight">{{ shell.name }}</span>
              <span class="block text-[10px] text-white/32 mt-3">Objects: {{ shell.object_budget }} max</span>
              <span v-if="permissions.ownedShellIds.includes(shell.id)" class="block text-[10px] text-white/32">You own this shell</span>
            </span>
          </button>

          <div v-if="shells.length === 0" class="text-[12px] text-white/35 text-center py-6">No shells yet</div>
        </div>

        <!-- detail -->
        <div class="shrink-0 flex flex-col" style="width:520px">
          <template v-if="selected">
            <div class="text-[18px] font-semibold uppercase tracking-wide mb-2.5">{{ selected.name }}</div>
            <div class="grid grid-cols-2 gap-x-6 gap-y-1.5 mt-3.5 text-[12px]">
              <div><span class="text-white/40">ID:</span> {{ selected.id }}</div>
              <div><span class="text-white/40">Timecycle:</span> {{ selected.timecycle }}</div>
              <div><span class="text-white/40">Budget:</span> {{ selected.object_budget }}</div>
            </div>
            <div class="grid grid-cols-2 gap-2 mt-4">
              <button v-if="isOwner(selected.id)" @click="enter(selected.id)"
                class="h-[38px] rounded-[7px] text-[12.5px] font-semibold uppercase tracking-wide"
                style="background:var(--ob-accent);color:#04120d">Enter</button>
              <button v-if="permissions.canBuild" @click="edit(selected.id)"
                class="h-[38px] rounded-[7px] text-[12.5px] font-semibold uppercase tracking-wide"
                style="background:var(--ob-accent);color:#04120d">Edit</button>
            </div>

            <div v-if="permissions.canBuild && selected" class="mt-4 pt-4" style="border-top:1px solid color-mix(in oklab, var(--ob-accent) 25%, transparent)">
              <div class="text-[12px] font-semibold uppercase tracking-wide mb-2">Manage owners</div>
              <div class="flex flex-col gap-1 mb-2">
                <div v-for="ownerId in currentOwners" :key="ownerId" class="flex items-center justify-between text-[12px] py-1">
                  <span>Character #{{ ownerId }}</span>
                  <button @click="removeOwner(ownerId)" class="text-[11px] px-2 py-0.5 rounded" style="border:1px solid rgba(239,68,68,.4);color:#fca5a5">Remove</button>
                </div>
              </div>
              <input v-model="ownerSearch" @input="searchOwners" placeholder="Search character name..."
                class="w-full h-[30px] rounded-[6px] px-2 text-[12px] bg-black/40 outline-none mb-1"
                style="border:1px solid rgba(255,255,255,.12)" />
              <div v-for="result in ownerSearchResults" :key="result.id" class="flex items-center justify-between text-[12px] py-1">
                <span>{{ result.first_name }} {{ result.last_name }}</span>
                <button @click="addOwner(result.id)" class="text-[11px] px-2 py-0.5 rounded" style="background:var(--ob-accent);color:#04120d">Add</button>
              </div>
            </div>
          </template>
          <div v-else class="text-[12px] text-white/35">Select a shell</div>
        </div>
      </div>

      <div class="shrink-0 px-5 py-3.5">
        <button @click="close"
          class="w-full h-[38px] rounded-[7px] text-[13px] font-semibold uppercase tracking-wide"
          style="border:1px solid color-mix(in oklab, var(--ob-accent) 45%, transparent);color:rgba(255,255,255,.75)">
          Exit
        </button>
      </div>
    </div>

    <div v-if="creating" class="absolute inset-0 z-30 grid place-items-center" style="background:rgba(0,0,0,.55)" @click="creating = false">
      <div @click.stop class="rounded-[12px] p-5" style="width:360px;background:color-mix(in oklab, var(--ob-accent) 6%, rgba(8,11,10,.96));border:1px solid color-mix(in oklab, var(--ob-accent) 40%, transparent)">
        <div class="text-[15px] font-semibold uppercase tracking-wide mb-3">New shell</div>
        <input v-model="newName" placeholder="Shell name"
          class="w-full h-[34px] rounded-[6px] px-2.5 text-[12.5px] bg-black/45 outline-none mb-3"
          style="border:1px solid color-mix(in oklab, var(--ob-accent) 45%, transparent)" />
        <button @click="createShell"
          class="w-full h-[38px] rounded-[7px] text-[12.5px] font-semibold uppercase tracking-wide"
          style="background:var(--ob-accent);color:#04120d">Create</button>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, watch, onUnmounted } from 'vue'
import Obelisk from '../../../web/src/obelisk.js'

const shells = ref([])
const permissions = ref({ canBuild: false, ownedShellIds: [] })
const selectedId = ref(null)
const creating = ref(false)
const newName = ref('')

const currentOwners = ref([])
const ownerSearch = ref('')
const ownerSearchResults = ref([])

const selected = computed(() => shells.value.find(s => s.id === selectedId.value) || null)

// The sync payload doesn't carry each shell's owner list, so there's no
// source to populate currentOwners from when a shell is first selected.
// Keeping this minimal: reset to empty on selection and let it fill in as
// add/remove roundtrips arrive via shellbuilder:ownersUpdated, rather than
// adding a dedicated "fetch owners" event for a staff panel this small.
watch(selectedId, () => {
  currentOwners.value = []
  ownerSearch.value = ''
  ownerSearchResults.value = []
})

function isOwner(shellId) {
  return permissions.value.ownedShellIds.includes(shellId)
}

function rowStyle(shellId) {
  const on = shellId === selectedId.value
  return {
    background: on ? 'color-mix(in oklab, var(--ob-accent) 13%, transparent)' : 'rgba(255,255,255,.03)',
    border: `1px solid ${on ? 'var(--ob-accent)' : 'color-mix(in oklab, var(--ob-accent) 22%, transparent)'}`,
  }
}

function createShell() {
  if (!newName.value.trim()) return
  Obelisk.emit('shellbuilder:create', { name: newName.value.trim() })
  creating.value = false
  newName.value = ''
}

function enter(shellId) {
  Obelisk.emit('shellbuilder:enter', { shellId })
}

function edit(shellId) {
  Obelisk.emit('shellbuilder:edit', { shellId })
}

function close() {
  Obelisk.emit('core:client:close', {})
}

function searchOwners() {
  Obelisk.emit('shellbuilder:searchCharacters', { query: ownerSearch.value })
}

function addOwner(characterId) {
  if (!selected.value) return
  Obelisk.emit('shellbuilder:addOwner', { shellId: selected.value.id, characterId })
}

function removeOwner(characterId) {
  if (!selected.value) return
  Obelisk.emit('shellbuilder:removeOwner', { shellId: selected.value.id, characterId })
}

// Named handler for sync event to enable proper cleanup
const onShellSync = (payload) => {
  shells.value = payload.shells || []
  permissions.value = payload.permissions || { canBuild: false, ownedShellIds: [] }
  if (!selectedId.value && shells.value.length) {
    selectedId.value = shells.value[0].id
  }
}

// Named handlers for the owner-management panel's listeners, cleaned up
// the same way as onShellSync.
const onCharacterSearchResults = (results) => {
  ownerSearchResults.value = results || []
}

const onOwnersUpdated = (payload) => {
  if (selected.value && payload.shellId === selected.value.id) {
    currentOwners.value = payload.owners || []
  }
}

Obelisk.on('shellbuilder:sync', onShellSync)
Obelisk.on('shellbuilder:characterSearchResults', onCharacterSearchResults)
Obelisk.on('shellbuilder:ownersUpdated', onOwnersUpdated)

// Unregister listener when component unmounts to prevent listener buildup
onUnmounted(() => {
  Obelisk.off('shellbuilder:sync', onShellSync)
  Obelisk.off('shellbuilder:characterSearchResults', onCharacterSearchResults)
  Obelisk.off('shellbuilder:ownersUpdated', onOwnersUpdated)
})
</script>
