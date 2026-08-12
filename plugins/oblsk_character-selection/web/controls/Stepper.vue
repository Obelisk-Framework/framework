<template>
  <div>
    <div class="ob-mono text-[9px] uppercase text-white/30 mb-1">{{ label }}</div>
    <div class="h-9 rounded-lg bg-black/40 border border-white/12 flex items-center">
      <button @click="set(modelValue - 1)" class="w-7 h-full grid place-items-center text-white/40 hover:text-white text-[13px] leading-none">−</button>
      <input
        :value="pad ? String(modelValue).padStart(2, '0') : modelValue"
        @change="onInput"
        class="flex-1 min-w-0 bg-transparent text-center outline-none ob-mono text-[12px]"
      />
      <button @click="set(modelValue + 1)" class="w-7 h-full grid place-items-center text-white/40 hover:text-white text-[13px] leading-none">+</button>
    </div>
  </div>
</template>

<script setup>
const props = defineProps({
  label: { type: String, required: true },
  modelValue: { type: Number, required: true },
  min: { type: Number, required: true },
  max: { type: Number, required: true },
  pad: { type: Boolean, default: false },
})
const emit = defineEmits(['update:modelValue'])

function clamp(n) {
  return Math.min(props.max, Math.max(props.min, n))
}
function set(n) {
  emit('update:modelValue', clamp(n))
}
function onInput(e) {
  const n = parseInt(e.target.value.replace(/\D/g, ''), 10)
  if (!isNaN(n)) set(n)
}
</script>
