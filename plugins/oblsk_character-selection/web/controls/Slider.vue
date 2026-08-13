<template>
  <div class="mb-3">
    <div class="flex justify-between text-[11px] mb-1">
      <span class="text-white/45">{{ label }}</span>
      <span class="ob-mono text-white/70">{{ modelValue }}</span>
    </div>
    <input
      type="range" min="0" max="100" :value="modelValue"
      @input="$emit('update:modelValue', +$event.target.value)"
      class="w-full h-1 appearance-none rounded-full bg-white/12 outline-none accent-ob-accent"
    />
  </div>
</template>

<script setup>
defineProps({ label: { type: String, required: true }, modelValue: { type: Number, required: true } })
defineEmits(['update:modelValue'])
</script>
