<template>
  <div class="absolute inset-0 select-none">
    <div class="absolute flex items-center gap-2.5" style="left:28px;top:22px">
      <div class="w-8 h-8 rounded-lg grid place-items-center bg-ob-accent">
        <span class="ob-mono text-[10px] text-black">OB</span>
      </div>
      <div>
        <div class="text-[13px] font-semibold leading-tight">Obelisk · Server 01</div>
        <div class="ob-mono text-[9px] text-white/45">{{ characters.length }} CHARACTER{{ characters.length === 1 ? '' : 'S' }}</div>
      </div>
    </div>

    <div class="absolute flex gap-1 rounded-lg border border-white/12 bg-[#0d1012] p-1" style="left:50%;top:22px;transform:translateX(-50%)">
      <span class="ob-mono text-[9px] text-white/30 self-center px-1.5">CAMERA</span>
      <button
        v-for="opt in [['head','Head'],['torso','Torso'],['full','Full body']]" :key="opt[0]"
        @click="setFraming(opt[0])"
        class="h-6 px-2.5 rounded-md text-[10.5px] transition"
        :class="framing === opt[0] ? 'text-black font-medium bg-ob-accent' : 'text-white/45 hover:bg-white/8'"
      >{{ opt[1] }}</button>
    </div>

    <div class="absolute rounded-xl border border-white/12 bg-[#0d1012] overflow-hidden" style="left:28px;top:76px;width:300px">
      <div class="h-8 px-3 flex items-center justify-between border-b border-white/8">
        <span class="ob-mono text-[12px] tracking-[0.2em] text-white/35">CHARACTERS · {{ characters.length }}</span>
        <span class="ob-mono text-[9px] text-white/25">W / S</span>
      </div>
      <div class="p-1.5 space-y-1">
        <button
          v-for="(entry, i) in characters" :key="entry.character.id"
          @click="selectedIndex = i"
          class="w-full flex items-center gap-2.5 px-2.5 py-2 rounded-md text-left transition"
          :class="i === selectedIndex ? 'text-black bg-ob-accent' : 'text-white/60 hover:text-white hover:bg-white/8'"
        >
          <span class="flex-1 min-w-0 block text-[12.5px] font-medium truncate">{{ entry.character.first_name }} {{ entry.character.last_name }}</span>
          <span class="ob-mono text-[9px] shrink-0" :class="i === selectedIndex ? 'text-black/55' : 'text-white/25'">{{ entry.character.last_played_at || 'Never' }}</span>
        </button>
        <button
          @click="$emit('create')"
          class="w-full flex items-center gap-2.5 px-2.5 py-2 rounded-md border border-dashed border-white/15 hover:border-ob-accent/60 hover:bg-white/6 transition text-left"
        >
          <span class="flex-1 text-[12.5px] text-white/55">+ Create new character</span>
        </button>
      </div>
    </div>

    <div v-if="selected" class="absolute rounded-xl border border-white/12 bg-[#0d1012] p-3.5" style="left:28px;bottom:96px;width:300px">
      <div class="ob-mono text-[9px] tracking-[0.2em] text-white/30 mb-2">SELECTED</div>
      <div class="text-[19px] font-semibold leading-tight mb-3">{{ selected.character.first_name }} {{ selected.character.last_name }}</div>
      <div class="space-y-1">
        <div class="flex items-baseline justify-between text-[11.5px]">
          <span class="ob-mono text-[10px] uppercase text-white/30">Date of birth</span>
          <span>{{ selected.character.dob }}</span>
        </div>
        <div class="flex items-baseline justify-between text-[11.5px]">
          <span class="ob-mono text-[10px] uppercase text-white/30">Last seen</span>
          <span>{{ selected.character.last_played_at || 'Never' }}</span>
        </div>
      </div>
    </div>

    <div v-if="selected" class="absolute rounded-xl border border-white/12 bg-black/62 p-3.5" style="right:28px;bottom:96px;width:300px">
      <div class="ob-mono text-[9px] tracking-[0.2em] text-white/35 mb-2">SPAWN POINT</div>
      <button
        @click="select(selected.character.id)"
        class="w-full h-10 rounded-lg text-black text-[13px] font-semibold bg-ob-accent"
      >Play as {{ selected.character.first_name }}</button>
    </div>

    <div class="absolute left-0 right-0 flex items-center justify-center gap-4" style="bottom:34px">
      <div v-for="[k, l] in [['W / S','Character'],['N','New character'],['ENTER','Play']]" :key="k" class="flex items-center gap-1.5">
        <span class="ob-mono inline-grid place-items-center h-[17px] rounded shrink-0 px-1.5 text-[9px] bg-white/13 border border-white/20">{{ k }}</span>
        <span class="text-[10px] text-white/50">{{ l }}</span>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted, onUnmounted } from 'vue'
import { useCharacterSelection } from './useCharacterSelection.js'

const emit = defineEmits(['create'])
const { characters, selectedIndex, selected, list, select, updatePreview } = useCharacterSelection()
const framing = ref('full')

function setFraming(f) {
  framing.value = f
  updatePreview({ cameraFraming: f })
}

function onKey(e) {
  const k = e.key.toLowerCase()
  if (k === 'w' || k === 'arrowup') { e.preventDefault(); selectedIndex.value = (selectedIndex.value - 1 + characters.value.length) % characters.value.length }
  if (k === 's' || k === 'arrowdown') { e.preventDefault(); selectedIndex.value = (selectedIndex.value + 1) % characters.value.length }
  if (k === 'n') emit('create')
  if (k === 'enter' && selected.value) select(selected.value.character.id)
}

onMounted(() => {
  list()
  window.addEventListener('keydown', onKey)
})
onUnmounted(() => window.removeEventListener('keydown', onKey))
</script>
