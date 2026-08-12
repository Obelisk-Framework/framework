<template>
  <div class="mb-3">
    <label class="text-[11px] text-white/45 block mb-1.5">{{ label }}</label>
    <input
      :value="modelValue" @input="$emit('update:modelValue', $event.target.value)"
      class="w-full h-9 px-3 rounded-lg bg-black/40 border border-white/12 text-[12.5px] outline-none focus:border-ob-accent"
    />
  </div>
</template>

<script setup>
defineProps({ label: { type: String, required: true }, modelValue: { type: String, required: true } })
defineEmits(['update:modelValue'])
</script>
