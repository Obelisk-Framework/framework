<!-- core/plugins/oblsk_barber/web/Barber.vue -->
<!-- Barber shop — ported from the Claude Design reference's BarberUI
     (src/proto/barber.jsx): tall menu rail with a banner, collapsible
     numbered/colour-swatch sections, and paying-the-barber sheets.
     Two required deviations from the design source (see task-7 brief):
       1. The 'hair' section renders real per-style JPEG thumbnails
          (Appearance.HAIR_STYLES via oblsk_character-selection's
          getHairStyles export, delivered through barber:sync) instead of
          the design's abstract numbered tiles.
       2. Payment drops the design's inline CARDS.map card picker entirely
          and instead calls the shared `obelisk:payment` picker (same
          pattern as TerminalPay.vue) for the CARD path.
     The design's shared Icon component (chevD/bank/check) isn't ported —
     out of scope per the brief — small inline SVGs stand in for the
     chevron and checkmark, and the CARD button is text-only. -->
<template>
  <div class="absolute inset-0">
    <!-- leave hint -->
    <div class="absolute right-8 top-5 flex items-center gap-2 rounded-[6px] px-3 h-[34px]"
      style="background:rgba(9,12,12,.85);border:1px solid rgba(255,255,255,.12)">
      <span class="ob-mono text-[10.5px] px-1.5 h-[20px] flex items-center rounded-[3px]"
        style="background:rgba(255,255,255,.09);border:1px solid rgba(255,255,255,.18);color:#fff">ESC</span>
      <span class="text-[12px] text-white/55">Leave the chair</span>
      <button @click="owned = !owned"
        class="ml-2 ob-mono text-[9.5px] tracking-[0.14em] px-2 h-[22px] rounded-[4px] transition hover:brightness-125"
        :style="{
          background: owned ? 'color-mix(in oklab, var(--ob-accent) 24%, transparent)' : 'rgba(255,255,255,.06)',
          border: `1px solid ${owned ? 'var(--ob-accent)' : 'rgba(255,255,255,.16)'}`,
          color: owned ? 'var(--ob-accent)' : 'rgba(255,255,255,.5)',
        }">
        {{ owned ? 'PLAYER OWNED' : 'SHOP MODE' }}
      </button>
    </div>

    <!-- the rail -->
    <div class="absolute left-8 top-5 bottom-5 flex flex-col rounded-[10px] overflow-hidden"
      style="width:470px;background:#0c0f0f;border:1px solid rgba(255,255,255,.1)">

      <!-- banner -->
      <div class="relative shrink-0 h-[132px] overflow-hidden">
        <svg viewBox="0 0 470 132" preserveAspectRatio="none" class="absolute inset-0 w-full h-full">
          <defs>
            <linearGradient id="bb-sky" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0" stop-color="color-mix(in oklab, var(--ob-accent) 30%, #1b1210)" />
              <stop offset="0.55" stop-color="color-mix(in oklab, var(--ob-accent) 62%, #241512)" />
              <stop offset="1" stop-color="color-mix(in oklab, var(--ob-accent) 18%, #0a0d0c)" />
            </linearGradient>
          </defs>
          <rect width="470" height="132" fill="url(#bb-sky)" />
          <circle cx="352" cy="52" r="34" fill="color-mix(in oklab, var(--ob-accent) 55%, #ffffff)" opacity="0.28" />
          <path d="M0 108 q60 -22 118 -6 q64 18 122 -6 q62 -24 122 2 q54 22 108 6 v28 H0z" fill="#0b0f0d" opacity="0.85" />
        </svg>
        <div v-for="side in ['left-0', 'right-0']" :key="side"
          :class="`absolute ${side} top-0 bottom-0 w-[26px] z-[2] flex flex-col items-center`">
          <svg viewBox="0 0 26 15" class="w-full shrink-0" style="height:15px">
            <ellipse cx="13" cy="5" rx="12" ry="4" fill="color-mix(in oklab, var(--ob-accent) 26%, #4b5c55)" />
            <rect x="1" y="5" width="24" height="7" fill="color-mix(in oklab, var(--ob-accent) 20%, #38463f)" />
            <ellipse cx="13" cy="12" rx="12" ry="3.4" fill="color-mix(in oklab, var(--ob-accent) 12%, #232c28)" />
          </svg>
          <div class="flex-1 w-[22px] overflow-hidden relative" style="box-shadow:inset 3px 0 6px rgba(0,0,0,.55), inset -3px 0 6px rgba(0,0,0,.55)">
            <div class="absolute left-0 w-full bb-pole-stripe" style="top:-100%;height:300%"></div>
          </div>
          <svg viewBox="0 0 26 15" class="w-full shrink-0" style="height:15px">
            <ellipse cx="13" cy="10" rx="12" ry="4" fill="color-mix(in oklab, var(--ob-accent) 12%, #232c28)" />
            <rect x="1" y="3" width="24" height="7" fill="color-mix(in oklab, var(--ob-accent) 20%, #38463f)" />
            <ellipse cx="13" cy="3" rx="12" ry="3.4" fill="color-mix(in oklab, var(--ob-accent) 26%, #4b5c55)" />
          </svg>
        </div>
        <div class="relative h-full grid place-items-center text-center px-6">
          <div class="text-[34px] font-semibold tracking-[0.3em] leading-none text-white uppercase"
            style="text-shadow:0 3px 14px rgba(0,0,0,.75)">Barber</div>
        </div>
      </div>

      <!-- sections -->
      <div class="flex-1 min-h-0 overflow-y-auto overscroll-contain ob-no-scroll p-2.5 flex flex-col gap-1.5">
        <div v-for="sec in allSections" :key="sec.id" class="rounded-[6px] overflow-hidden shrink-0"
          :style="{ border: `1px solid ${open === sec.id ? 'rgba(255,255,255,.16)' : 'rgba(255,255,255,.08)'}` }">
          <button @click="toggle(sec.id)"
            class="w-full h-[38px] px-3 flex items-center gap-2 transition"
            :style="{ background: open === sec.id ? 'rgba(255,255,255,.07)' : 'rgba(255,255,255,.035)' }">
            <span class="text-[14px] flex-1 text-left" :style="{ color: open === sec.id ? '#fff' : 'rgba(255,255,255,.8)' }">{{ sec.label }}</span>
            <span v-if="touched[sec.id]" class="ob-mono text-[9.5px] px-1.5 h-[17px] flex items-center rounded-[3px]"
              style="background:color-mix(in oklab, var(--ob-accent) 22%, transparent);color:var(--ob-accent)">+${{ sec.price }}</span>
            <span class="ob-mono text-[11px] text-white/40">Click</span>
            <span class="w-[22px] h-[20px] rounded-[3px] grid place-items-center transition-transform"
              style="background:rgba(255,255,255,.07)"
              :style="{ transform: open === sec.id ? 'rotate(180deg)' : 'rotate(0deg)' }">
              <svg width="10" height="6" viewBox="0 0 10 6" fill="none"><path d="M1 1l4 4 4-4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" /></svg>
            </span>
          </button>

          <div v-if="open === sec.id" class="p-2.5" style="background:rgba(0,0,0,.35)">
            <!-- hair: real thumbnails -->
            <div v-if="sec.id === 'hair'" class="grid grid-cols-4 gap-2 overflow-y-auto overscroll-contain ob-no-scroll pr-0.5" style="max-height:300px">
              <button
                v-for="style in hairStyles"
                :key="style.drawable"
                @click="pickHair(style)"
                class="relative rounded-[5px] p-1 transition"
                :style="{
                  background: picks.hair === style.drawable ? 'color-mix(in oklab, var(--ob-accent) 12%, #0a0d0c)' : '#0a0d0c',
                  border: `1px solid ${picks.hair === style.drawable ? 'var(--ob-accent)' : 'rgba(255,255,255,.09)'}`,
                  height: '92px',
                }"
              >
                <img :src="`assets/hair/${gender}/${style.drawable}.jpg`" :alt="style.label" class="w-full h-full object-cover rounded-[4px]" />
                <span
                  class="absolute bottom-1 right-1.5 ob-mono text-[10px]"
                  :style="{ color: picks.hair === style.drawable ? 'var(--ob-accent)' : 'rgba(255,255,255,.55)' }"
                >{{ style.drawable }}</span>
              </button>
            </div>

            <!-- other 'style' sections: numbered index cards -->
            <div v-else-if="sec.kind === 'style'" class="grid grid-cols-4 gap-2 overflow-y-auto overscroll-contain ob-no-scroll pr-0.5" style="max-height:300px">
              <button v-for="n in sec.count" :key="n - 1" @click="pickStyle(sec, n - 1)"
                class="relative rounded-[5px] p-1 transition"
                :style="{
                  background: picks[sec.id] === n - 1 ? 'color-mix(in oklab, var(--ob-accent) 12%, #0a0d0c)' : '#0a0d0c',
                  border: `1px solid ${picks[sec.id] === n - 1 ? 'var(--ob-accent)' : 'rgba(255,255,255,.09)'}`,
                  height: '92px',
                }">
                <span class="absolute bottom-1 right-1.5 ob-mono text-[10px]"
                  :style="{ color: picks[sec.id] === n - 1 ? 'var(--ob-accent)' : 'rgba(255,255,255,.55)' }">{{ n - 1 === 0 ? 'None' : n - 1 }}</span>
              </button>
            </div>

            <!-- 'colour' sections: swatch grid -->
            <div v-else class="grid grid-cols-8 gap-2 overflow-y-auto overscroll-contain ob-no-scroll pr-0.5" style="max-height:240px">
              <button v-for="i in sec.count" :key="i - 1" @click="pickColour(sec, i - 1)"
                class="h-[30px] rounded-[5px] transition"
                :style="{
                  background: tone(i - 1),
                  boxShadow: cols[sec.id] === i - 1 ? '0 0 0 2px #fff' : 'inset 0 0 0 1px rgba(255,255,255,.2)',
                }" />
            </div>
          </div>
        </div>
      </div>

      <!-- footer -->
      <div class="shrink-0 p-2.5" style="border-top:1px solid rgba(255,255,255,.08)">
        <button :disabled="!total" @click="onFooterClick"
          class="w-full h-[42px] rounded-[6px] font-semibold text-[14px] transition enabled:hover:brightness-110 disabled:opacity-35 disabled:cursor-not-allowed"
          style="background:var(--ob-accent);color:#04120d">{{ owned ? 'Cut it' : `Pay (€${total})` }}</button>
      </div>
    </div>

    <!-- paying the barber — cash, or one of your cards -->
    <div v-if="pay === 'method'" class="absolute inset-0 z-40 flex items-end justify-center" style="background:rgba(0,0,0,.62)" @click="pay = null">
      <div class="w-full max-w-[880px] pb-8" @click.stop>
        <div class="text-center mb-5">
          <div class="ob-mono text-[10px] tracking-[0.25em]" style="color:var(--ob-accent)">HOW ARE YOU PAYING?</div>
          <div class="text-[19px] font-semibold mt-1.5 uppercase">{{ Object.keys(touched).length }} changes · €{{ total }}</div>
        </div>
        <div class="flex justify-center gap-3">
          <button @click="payByCash"
            class="w-[210px] h-[52px] rounded-[8px] font-semibold text-[14px] flex items-center justify-center gap-2 transition hover:bg-white/[0.09]"
            style="background:rgba(10,14,18,.8);border:1px solid rgba(255,255,255,.16);color:#fff">
            <span class="ob-mono text-[13px]">€</span> CASH
          </button>
          <button @click="payByCard"
            class="w-[210px] h-[52px] rounded-[8px] font-semibold text-[14px] flex items-center justify-center gap-2 transition hover:brightness-110"
            style="background:var(--ob-accent);color:#04120d">
            CARD
          </button>
        </div>
      </div>
    </div>

    <!-- charge failure banner — deliberately NOT nested inside the payment
         sheet, so it's still visible on the owned/free path (which never
         opens that sheet) and stays up after the sheet auto-closes. -->
    <div v-if="chargeError" class="absolute left-1/2 top-5 z-50 -translate-x-1/2 flex items-center gap-2 rounded-[6px] px-3 h-[38px] max-w-[520px]"
      style="background:rgba(56,10,10,.92);border:1px solid rgba(255,120,120,.5)">
      <span class="text-[12px] text-white/90">{{ chargeError }}</span>
      <button @click="chargeError = null" class="ob-mono text-[11px] text-white/60 hover:text-white/90 transition">×</button>
    </div>

    <!-- receipt -->
    <div v-if="done" class="absolute inset-0 z-40 grid place-items-center" style="background:rgba(0,0,0,.6)" @click="done = null">
      <div class="rounded-[10px] p-7 text-center w-[330px]" style="background:rgba(10,14,18,.92);border:1px solid rgba(255,255,255,.12)" @click.stop>
        <svg width="28" height="28" viewBox="0 0 28 28" fill="none" class="mx-auto mb-2" style="color:var(--ob-accent)">
          <circle cx="14" cy="14" r="13" stroke="currentColor" stroke-width="1.5" />
          <path d="M8 14.5l4 4 8-9" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
        </svg>
        <div class="text-[16px] font-semibold uppercase">In the chair</div>
        <div class="ob-mono text-[22px] my-1.5" style="color:var(--ob-accent)">€{{ done.total }}</div>
        <div class="text-[12px] text-white/50">{{ receiptSubtitle }}</div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, inject, onMounted, onUnmounted, reactive, ref } from 'vue'
import Obelisk from '../../../web/src/obelisk.js'

const payment = inject('obelisk:payment')

// --- sync state (from barber:sync) ---------------------------------------
const chairId = ref(null)
const gender = ref('male')
const hairStyles = ref([])
const sections = ref([]) // Config.Sections — every non-hair section
const hairPrice = ref(0)

// 16 hair/skin tones the shop stocks, all inside the house palette — ported
// unchanged from the design's BB_TONES. Used for every 'colour' section's
// swatch grid (haircol/hl/beardcol/browcol/chestcol/blush/lipstick). NOTE:
// these are display swatches only; the picked *index* (0-based) is what
// gets sent to the server as the native colour/highlight/overlay-colour ID
// — see appearanceChangesFromTouched() below for why that's an
// approximation rather than a byte-exact mapping onto
// Appearance.HAIR_COLORS.
const BB_TONES = Array.from({ length: 16 }, (_, i) =>
  `color-mix(in oklab, var(--ob-accent) ${6 + i * 6}%, ${i % 2 ? '#f3ece2' : '#14100f'})`
)
function tone(i) {
  return BB_TONES[i % BB_TONES.length]
}

// hair is not part of Config.Sections (its real per-gender count comes from
// hairStyles, not a static count) — the UI re-adds it as the rail's first
// section, same slot the design's BB_SECTIONS gave it.
const allSections = computed(() => [
  { id: 'hair', label: 'Hair', kind: 'style', price: hairPrice.value },
  ...sections.value,
])

// --- picks / colours / touched -------------------------------------------
const open = ref('hair')
// Synchronous, matching the JSX reference's setOpen(...) — there's no exit
// animation in this port that would need a delayed close (an earlier
// revision here had a dead `closing` ref + setTimeout doing nothing but
// adding an unrequested ~420ms lag to switching sections).
function toggle(id) {
  open.value = open.value === id ? null : id
}

// Style-section picks (0-based UI option index; 0 = 'None'). Hair keeps the
// native drawable id directly (that's what pickHair/the thumbnail grid
// already work in).
const picks = reactive({ hair: 0, beard: 0, brows: 0, chest: 0, makeup: 0 })
// Colour-section picks: 0-based index into BB_TONES/the section's swatch
// grid.
const cols = reactive({ haircol: 0, hl: 0, beardcol: 0, browcol: 0, chestcol: 0, blush: 0, lipstick: 0 })
const touched = reactive({})

const total = computed(() =>
  allSections.value.filter(s => touched[s.id]).reduce((a, s) => a + s.price, 0)
)

function pickStyle(sec, n) {
  picks[sec.id] = n
  touched[sec.id] = true
}

function pickColour(sec, i) {
  cols[sec.id] = i
  touched[sec.id] = true
}

function pickHair(style) {
  picks.hair = style.drawable
  touched.hair = true
  Obelisk.emit('barber:preview', { appearance: { hairStyle: style.drawable } })
}

// --- serializing touched picks into a native-valued appearance partial ---
// Every overlay-backed section (beard/beardcol, brows/browcol,
// chest/chestcol, makeup, blush, lipstick) maps onto one of
// Appearance.OVERLAYS' keys (shared/appearance.lua, oblsk_character-selection).
// Those native overlayId/colorType values are hand-copied here (Lua tables
// aren't importable into the browser bundle — same reason
// appearancePresets.js exists for the character creator) rather than
// exported, since barber only needs this one static mapping table, not the
// full curated catalog.
const OVERLAY_TARGETS = {
  beard: { overlay: 'facial_hair', overlayId: 1 },
  beardcol: { overlay: 'facial_hair', overlayId: 1, colorType: 1 },
  brows: { overlay: 'eyebrows', overlayId: 2 },
  browcol: { overlay: 'eyebrows', overlayId: 2, colorType: 1 },
  chest: { overlay: 'chest_hair', overlayId: 10 },
  chestcol: { overlay: 'chest_hair', overlayId: 10, colorType: 1 },
  makeup: { overlay: 'makeup', overlayId: 4 },
  blush: { overlay: 'blush', overlayId: 5, colorType: 2 },
  lipstick: { overlay: 'lipstick', overlayId: 8, colorType: 2 },
}

// UI style-grid index 0 is always 'None'; native SetPedHeadOverlay style
// range is -1..N-1, so UI index N>0 maps to native (N-1) — same convention
// Appearance.resolvePresetAppearance uses for the character creator's own
// overlay picker.
function overlayNativeStyle(uiIndex) {
  return uiIndex > 0 ? uiIndex - 1 : -1
}

function appearanceChangesFromTouched() {
  const changes = {}
  const overlays = {}
  const ensureOverlay = (key, overlayId) => {
    if (!overlays[key]) overlays[key] = { overlayId, opacity: 1 }
    return overlays[key]
  }

  for (const id of Object.keys(touched)) {
    if (id === 'hair') {
      changes.hairStyle = picks.hair
    } else if (id === 'haircol') {
      changes.hairColor = cols.haircol
    } else if (id === 'hl') {
      changes.hairHighlight = cols.hl
    } else if (OVERLAY_TARGETS[id]) {
      const target = OVERLAY_TARGETS[id]
      const entry = ensureOverlay(target.overlay, target.overlayId)
      if (target.colorType) {
        entry.colorId = cols[id]
        entry.colorType = target.colorType
      } else {
        entry.styleIndex = overlayNativeStyle(picks[id])
      }
    }
  }

  if (Object.keys(overlays).length) changes.overlays = overlays
  return changes
}

// --- payment ---------------------------------------------------------
const pay = ref(null) // null | 'method'
const pendingMethod = ref(null)
const pendingCardId = ref(null)
// Set on a failed barber:chargeResult (see onChargeResult below). A failed
// charge must never look identical to a successful one — this is rendered
// as a standalone banner (not nested inside the payment sheet) so it's
// still visible even on the owned/free path, which never opens that sheet.
// Worst case here is the CARD path: payment.requestPayment() may have
// already billed the card before barber:charge was even emitted, so a
// later server-side failure (e.g. persistence) needs a loud, visible
// warning, not a silently-closed sheet.
const chargeError = ref(null)

function onFooterClick() {
  if (!total.value) return
  chargeError.value = null
  if (owned.value) {
    pendingMethod.value = 'free'
    pendingCardId.value = null
    Obelisk.emit('barber:applyFree', { appearanceChanges: appearanceChangesFromTouched() })
    return
  }
  pay.value = 'method'
}

async function payByCard() {
  chargeError.value = null
  const result = await payment.requestPayment({ amount: total.value, description: 'Barber shop' })
  if (!result.ok) return
  pendingMethod.value = 'card'
  pendingCardId.value = result.cardId
  emitCharge('card', result.cardId)
}

function payByCash() {
  chargeError.value = null
  pendingMethod.value = 'cash'
  pendingCardId.value = null
  emitCharge('cash', null)
}

function emitCharge(method, cardId) {
  Obelisk.emit('barber:charge', {
    touchedSectionIds: Object.keys(touched),
    method,
    cardId,
    appearanceChanges: appearanceChangesFromTouched(),
  })
}

// --- misc UI state -----------------------------------------------------
const owned = ref(false)
const done = ref(null) // { total, method, cardId } | null

const receiptSubtitle = computed(() => {
  if (!done.value) return ''
  if (done.value.method === 'cash') return 'Paid in cash'
  if (done.value.method === 'card') return `Card ${done.value.cardId != null ? '#' + done.value.cardId : ''}`.trim()
  if (done.value.method === 'free') return 'No charge (player owned)'
  return ''
})

// --- NUI wiring ----------------------------------------------------------
function onSync(payload) {
  chairId.value = payload.chairId
  gender.value = payload.gender
  hairStyles.value = payload.hairStyles || []
  sections.value = payload.sections || []
  hairPrice.value = payload.hairPrice || 0
}

// Single shared completion handler for BOTH the paid path
// (barber:client:charge on the server) and the owned/free path
// (barber:client:applyFree) — server/main.lua emits the same
// barber:server:chargeResult event (relayed here as barber:chargeResult)
// from both handlers on success, so there's no separate "free cut done"
// event to listen for; pendingMethod (set right before each emit, incl.
// the 'free' case in onFooterClick) is what tells the receipt/error UI
// which path just completed.
function onChargeResult(result) {
  pay.value = null
  if (!result || !result.ok) {
    chargeError.value = 'Something went wrong — you were not charged again, but please check with staff if a card payment did go through.'
    return
  }
  chargeError.value = null
  done.value = { total: result.total ?? 0, method: pendingMethod.value, cardId: pendingCardId.value }
  // A successful cut has been paid for and persisted — clear touched state
  // so the footer/price resets and the same picks aren't charged again.
  for (const key of Object.keys(touched)) delete touched[key]
}

Obelisk.on('barber:sync', onSync)
Obelisk.on('barber:chargeResult', onChargeResult)

function onKeydown(e) {
  if (e.key === 'Escape') Obelisk.emit('core:client:close', {})
}
onMounted(() => window.addEventListener('keydown', onKeydown))

onUnmounted(() => {
  Obelisk.off('barber:sync', onSync)
  Obelisk.off('barber:chargeResult', onChargeResult)
  window.removeEventListener('keydown', onKeydown)
})
</script>

<style scoped>
/* Ported unchanged from the design's <style> keyframes block: the
   barber-pole stripe scroll. */
.bb-pole-stripe {
  background: repeating-linear-gradient(
    135deg,
    color-mix(in oklab, var(--ob-accent) 72%, #cfe3da) 0 7px,
    color-mix(in oklab, var(--ob-accent) 38%, #04120d) 7px 14px,
    #05130f 14px 21px
  );
  animation: bbPole 2.6s linear infinite;
}
@keyframes bbPole {
  from { transform: translateY(0); }
  to { transform: translateY(33.333%); }
}
</style>

