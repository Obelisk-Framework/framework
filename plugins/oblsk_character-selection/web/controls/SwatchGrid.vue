<template>
  <div class="grid grid-cols-8 gap-1.5 mb-2">
    <button
      v-for="(preset, i) in presets" :key="i"
      @click="$emit('update:modelValue', i)"
      class="h-8 rounded-md transition"
      :style="{
        background: preset.swatch,
        outline: modelValue === i ? '2px solid var(--ob-accent)' : '1px solid rgba(255,255,255,.1)',
        outlineOffset: '2px',
      }"
    />
  </div>
</template>

<script setup>
defineProps({
  presets: { type: Array, required: true },
  modelValue: { type: Number, required: true },
})
defineEmits(['update:modelValue'])
</script>
