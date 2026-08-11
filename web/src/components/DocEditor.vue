<template>
  <div class="flex flex-col h-full">
    <div v-if="!readonly" class="flex gap-1.5 border-b border-white/8 pb-2 mb-2">
      <button @click="exec('bold')" class="px-2 h-6 rounded text-[11px] border border-white/12 hover:bg-white/8">B</button>
      <button @click="exec('italic')" class="px-2 h-6 rounded text-[11px] border border-white/12 hover:bg-white/8 italic">I</button>
      <button @click="$emit('sign')" class="px-2 h-6 rounded text-[11px] border border-white/12 hover:bg-white/8">Sign</button>
      <button @click="$emit('print')" class="px-2 h-6 rounded text-[11px] border border-white/12 hover:bg-white/8">Print</button>
    </div>
    <div ref="editorRef" :contenteditable="!readonly" class="flex-1 overflow-y-auto text-[12px] leading-relaxed outline-none"
      @input="onInput"></div>
  </div>
</template>

<script setup>
import { ref, onMounted, watch } from 'vue'

const props = defineProps({ modelValue: { type: String, default: '' }, readonly: { type: Boolean, default: false } })
const emit = defineEmits(['update:modelValue', 'sign', 'print'])
const editorRef = ref(null)

function onInput() {
  emit('update:modelValue', editorRef.value.innerHTML)
}
function exec(command) {
  editorRef.value.focus()
  document.execCommand(command, false, null)
  onInput()
}

onMounted(() => { if (editorRef.value) editorRef.value.innerHTML = props.modelValue })
watch(() => props.modelValue, (val) => {
  if (editorRef.value && editorRef.value.innerHTML !== val) editorRef.value.innerHTML = val
})
</script>
