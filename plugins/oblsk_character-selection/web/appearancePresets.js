// core/plugins/oblsk_character-selection/web/appearancePresets.js
// Mirrors core/plugins/oblsk_character-selection/shared/appearance.lua's
// swatch/label data for the browser UI. Lua tables aren't importable into
// Vue; this file owns only what the UI needs to RENDER (labels, swatches,
// option counts) — the actual drawable/texture/native IDs stay server/client
// Lua-side and are applied via character-selection:preview-update payloads
// that reference presets by index, not by re-sending IDs from the browser.
export const WARDROBE_SLOTS = [
  ['top', 'Top', ['Tee · black', 'Henley', 'Polo', 'Tank', 'Flannel', 'Hoodie']],
  ['jacket', 'Outerwear', ['None', 'Field jacket', 'Bomber', 'Leather', 'Denim']],
  ['pants', 'Legwear', ['Jeans', 'Cargo · khaki', 'Chinos', 'Joggers', 'Tactical']],
  ['shoes', 'Footwear', ['Sneakers', 'Combat boots', 'Runners', 'Dress shoes']],
  ['hat', 'Headwear', ['None', 'Ball cap', 'Beanie', 'Bandana']],
  ['acc', 'Accessory', ['None', 'Watch', 'Chain', 'Glasses']],
]

export const SKIN_TONES = ['#3a2418', '#4a2e1e', '#5e3b25', '#7a4f33', '#9a6a48', '#b88761', '#d2a47e', '#e8c39c'].map(swatch => ({ swatch }))
export const EYE_COLORS = ['#2a4a6e', '#3b6e8f', '#4a8e4a', '#6b5b3a', '#3a3a3a', '#7a4a2a', '#1a3a3a', '#5a2a4a'].map(swatch => ({ swatch }))
export const HAIR_COLORS = ['#0e0d0c', '#2b1d15', '#4a2f1c', '#7a4a22', '#b07a34', '#d9b877', '#8a8a8a', '#c94f2a'].map(swatch => ({ swatch }))
export const HAIR_STYLE_COUNT = 6

export const SLIDER_LABELS = [
  ['nose', 'Nose width'], ['noseH', 'Nose height'], ['cheek', 'Cheekbones'], ['jaw', 'Jaw width'],
  ['chin', 'Chin length'], ['brow', 'Brow height'], ['eyeSize', 'Eye size'], ['lips', 'Lip fullness'],
]
