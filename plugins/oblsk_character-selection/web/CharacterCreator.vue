<!-- core/plugins/oblsk_character-selection/web/CharacterCreator.vue -->
<template>
  <div class="absolute inset-0 grid" style="grid-template-columns:392px 1fr">
    <div class="border-r border-white/8 bg-[#0d1012] flex flex-col min-h-0">
      <div class="p-5 pb-4 shrink-0">
        <button @click="$emit('back')" class="mb-5 text-[12.5px] text-white/45 hover:text-white">← Back to roster</button>
        <h2 class="text-[22px] font-semibold tracking-tight">New character</h2>
        <p class="text-[12px] text-white/40 mb-4">Step {{ step + 1 }} of {{ STEPS.length }} · {{ STEPS[step] }}</p>
        <div class="flex gap-1 mb-4">
          <div v-for="(_, i) in STEPS" :key="i" class="flex-1 h-1 rounded-full transition" :class="i <= step ? 'bg-ob-accent' : 'bg-white/10'" />
        </div>
        <div class="grid grid-cols-2 gap-1.5">
          <button
            v-for="(s, i) in STEPS" :key="s" @click="step = i"
            class="h-9 px-3 rounded-lg text-[12.5px] flex items-center justify-between gap-2 transition"
            :class="i === step ? 'text-black font-medium bg-ob-accent' : i < step ? 'bg-white/[0.06] text-white/60' : 'bg-white/[0.03] text-white/30'"
          ><span class="truncate">{{ s }}</span></button>
        </div>
        <div v-if="step === 2" class="flex gap-1 mt-3">
          <button
            v-for="t in ['face','hair','body']" :key="t" @click="tab = t"
            class="flex-1 h-8 rounded-lg text-[11.5px] capitalize transition"
            :class="tab === t ? 'text-black font-medium bg-ob-accent' : 'bg-white/[0.04] text-white/45'"
          >{{ t }}</button>
        </div>
      </div>

      <div class="flex-1 overflow-y-auto ob-no-scroll px-5 pb-5">
        <template v-if="step === 0">
          <TextField label="First name" v-model="form.first" />
          <TextField label="Surname" v-model="form.last" />
          <div class="flex gap-1.5 mb-4">
            <button
              v-for="s in ['male','female']" :key="s" @click="setGender(s)"
              class="flex-1 h-9 rounded-lg text-[12px] capitalize transition"
              :class="form.sex === s ? 'text-black font-medium bg-ob-accent' : 'bg-white/6 text-white/50'"
            >{{ s }}</button>
          </div>
          <div class="grid grid-cols-3 gap-2">
            <Stepper label="Year" v-model="form.dobY" :min="1960" :max="2008" />
            <Stepper label="Month" v-model="form.dobM" :min="1" :max="12" pad />
            <Stepper label="Day" v-model="form.dobD" :min="1" :max="31" pad />
          </div>
        </template>

        <template v-else-if="step === 1">
          <p class="text-[11.5px] text-white/40 mb-4 leading-relaxed">Parent resemblance blends facial shape and skin tone. Locked once confirmed.</p>
          <Stepper label="Mother head" v-model="form.headBlend.shapeFirst" :min="0" :max="45" />
          <Stepper label="Father head" v-model="form.headBlend.shapeSecond" :min="0" :max="45" />
          <Slider label="Mother ← → Father (shape)" v-model="shapeMixPct" />
          <Slider label="Mother ← → Father (skin)" v-model="skinMixPct" />
        </template>

        <template v-else-if="step === 2">
          <template v-if="tab === 'face'">
            <Slider v-for="[key, label] in SLIDER_LABELS" :key="key" :label="label" v-model="form.faceFeaturesPct[key]" />
            <SwatchGrid :presets="SKIN_TONES" v-model="form.skinIndex" />
            <SwatchGrid :presets="EYE_COLORS" v-model="form.eyeIndex" />
          </template>
          <template v-else-if="tab === 'hair'">
            <SwatchGrid :presets="HAIR_COLORS" v-model="form.hairColorIndex" />
            <div class="grid grid-cols-3 gap-2">
              <button
                v-for="i in HAIR_STYLE_COUNT" :key="i" @click="form.hairStyleIndex = i - 1"
                class="aspect-square rounded-lg border text-[9px] ob-mono"
                :class="form.hairStyleIndex === i - 1 ? 'border-ob-accent text-ob-accent bg-ob-accent/10' : 'border-white/10 text-white/30'"
              >HAIR-{{ String(i).padStart(2, '0') }}</button>
            </div>
          </template>
          <template v-else-if="tab === 'body'">
            <div class="text-[12px] text-white/35 py-8 text-center">No native body-scale effect — stored for future use.</div>
          </template>
        </template>

        <template v-else-if="step === 3">
          <template v-for="[key, label, opts] in WARDROBE_SLOTS" :key="key">
            <div class="ob-mono text-[9px] tracking-[0.2em] uppercase text-white/30 mb-2.5 mt-4">{{ label }}</div>
            <div class="flex flex-wrap gap-1.5">
              <button
                v-for="(o, i) in opts" :key="o" @click="setWardrobe(key, i)"
                class="h-8 px-2.5 rounded-lg text-[11.5px] border transition"
                :class="form.fit[key] === i ? 'border-ob-accent bg-ob-accent/12 text-ob-accent' : 'border-white/10 text-white/50'"
              >{{ o }}</button>
            </div>
          </template>
        </template>
      </div>

      <div class="p-4 border-t border-white/8 shrink-0 flex gap-2">
        <button @click="step = Math.max(0, step - 1)" :disabled="step === 0" class="h-10 px-4 rounded-xl border border-white/12 text-[12.5px] disabled:opacity-25">Back</button>
        <button @click="next" class="flex-1 h-10 rounded-xl text-black text-[12.5px] font-semibold bg-ob-accent">
          {{ step === STEPS.length - 1 ? 'Enter the city' : `Continue → ${STEPS[step + 1]}` }}
        </button>
      </div>
    </div>

    <div class="relative flex flex-col min-w-0">
      <div class="absolute top-5 right-5 z-10 flex items-center gap-2">
        <button @click="cycleAngle" class="h-8 px-3 rounded-lg border border-white/12 bg-black/50 text-[11.5px]">F · Rotate</button>
      </div>
    </div>
  </div>
</template>

<script setup>
import { reactive, ref, computed, watch, onMounted, onUnmounted } from 'vue'
import { useCharacterSelection } from './useCharacterSelection.js'
import Slider from './controls/Slider.vue'
import SwatchGrid from './controls/SwatchGrid.vue'
import Stepper from './controls/Stepper.vue'
import TextField from './controls/TextField.vue'
import { WARDROBE_SLOTS, SKIN_TONES, EYE_COLORS, HAIR_COLORS, HAIR_STYLE_COUNT, SLIDER_LABELS } from './appearancePresets.js'

const emit = defineEmits(['back'])
const { create, updatePreview } = useCharacterSelection()

const STEPS = ['Identity', 'Heritage', 'Appearance', 'Wardrobe']
const step = ref(0)
const tab = ref('face')
const angle = ref(0)

const form = reactive({
  first: 'Alex', last: 'Reyes', sex: 'female',
  dobY: 1994, dobM: 3, dobD: 12,
  headBlend: { shapeFirst: 0, shapeSecond: 1, shapeThird: 0, skinFirst: 0, skinSecond: 1, skinThird: 0, shapeMix: 0.5, skinMix: 0.5, thirdMix: 0.0 },
  faceFeaturesPct: { nose: 50, noseH: 50, cheek: 50, jaw: 50, chin: 50, brow: 50, eyeSize: 50, lips: 50 },
  skinIndex: 4, eyeIndex: 2, hairColorIndex: 1, hairStyleIndex: 2,
  fit: { top: 0, jacket: 1, pants: 0, shoes: 0, hat: 0, acc: 0 },
})

const shapeMixPct = computed({
  get: () => Math.round(form.headBlend.shapeMix * 100),
  set: (v) => { form.headBlend.shapeMix = v / 100 },
})
const skinMixPct = computed({
  get: () => Math.round(form.headBlend.skinMix * 100),
  set: (v) => { form.headBlend.skinMix = v / 100 },
})

function setGender(sex) {
  form.sex = sex
  updatePreview({ gender: sex === 'female' ? 'female' : 'male' })
}

function setWardrobe(key, i) {
  form.fit[key] = i
  updatePreview({ wardrobeSlot: { key, optionIndex: i } })
}

function buildAppearance() {
  const faceFeatures = {}
  const FEATURE_INDEX = { nose: 0, noseH: 2, cheek: 6, jaw: 15, chin: 10, brow: 8, eyeSize: 13, lips: 17 }
  for (const [key, idx] of Object.entries(FEATURE_INDEX)) {
    faceFeatures[idx] = (form.faceFeaturesPct[key] - 50) / 50
  }
  return {
    headBlend: { ...form.headBlend },
    faceFeatures,
    hairStyle: form.hairStyleIndex,
    hairColor: form.hairColorIndex,
    hairHighlight: form.hairColorIndex,
    eyeColor: form.eyeIndex,
    components: {},
    props: {},
  }
}

watch(() => JSON.stringify(form), () => {
  updatePreview({ appearance: buildAppearance() })
}, { immediate: true })

function cycleAngle() {
  angle.value = (angle.value + 1) % 4
  updatePreview({ cameraAngle: angle.value })
}

function onKey(e) {
  const tag = e.target?.tagName
  if (tag === 'INPUT' || tag === 'TEXTAREA') return
  if (e.key.toLowerCase() === 'f') cycleAngle()
}

function next() {
  if (step.value === STEPS.length - 1) {
    create({
      first_name: form.first, last_name: form.last, gender: form.sex,
      dob: `${form.dobY}-${String(form.dobM).padStart(2, '0')}-${String(form.dobD).padStart(2, '0')}`,
      bio: '', appearance: buildAppearance(),
    })
    emit('back')
    return
  }
  step.value = Math.min(STEPS.length - 1, step.value + 1)
}

onMounted(() => window.addEventListener('keydown', onKey))
onUnmounted(() => window.removeEventListener('keydown', onKey))
</script>
