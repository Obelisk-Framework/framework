<template>
  <div class="h-full w-full relative bg-[#07090a] text-white">
    <CharacterSelect v-if="mode === 'select'" @create="mode = 'create'" />
    <CharacterCreator v-else @back="mode = 'select'" />
  </div>
</template>

<script setup>
import { ref } from 'vue'
import CharacterSelect from './CharacterSelect.vue'
import CharacterCreator from './CharacterCreator.vue'

const mode = ref('select')
</script>
