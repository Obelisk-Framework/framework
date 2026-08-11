// Dev-only fallback tree so /nativeMenu renders something without a live
// NUI event. Mirrors the garage/settings/emotes demo from the source design.
export function demoMenu() {
  return {
    title: 'OBELISK',
    sub: 'MAIN MENU',
    items: [
      {
        key: 'garage', label: 'Vehicle garage', type: 'menu',
        desc: 'Retrieve, store and inspect your vehicles.',
        items: [
          { key: 'v1', label: 'Karin Sultan RS', type: 'list', right: 'KW-491', desc: 'Sports · stored · fuel 78%' },
          { key: 'v2', label: 'Vapid Sandking XL', type: 'list', right: 'KW-002', desc: 'Off-road · stored · fuel 92%' },
          { key: 'v3', label: 'Pegassi Faggio', type: 'list', right: 'IMPOUND', desc: 'Moped · impounded · $480 release' },
          { key: 'v4', label: 'Police Buffalo', type: 'list', right: 'ON DUTY', desc: 'Emergency · currently out' },
          { key: 'take', label: 'Take out selected', type: 'action', desc: 'Spawn the highlighted vehicle at the gate.' },
        ],
      },
      {
        key: 'settings', label: 'Settings', type: 'menu',
        desc: 'Display, audio and gameplay options.',
        items: [
          {
            key: 'display', label: 'Display', type: 'menu',
            desc: 'Resolution, FOV and draw distance.',
            items: [
              { key: 'quality', label: 'Preset', type: 'select', value: 'High', options: ['Low', 'Medium', 'High', 'Ultra'], desc: 'Overall graphics preset.' },
              { key: 'fov', label: 'Field of view', type: 'slider', value: 62, min: 50, max: 100, unit: '°', desc: 'Camera field of view in first person.' },
              { key: 'draw', label: 'Draw distance', type: 'slider', value: 55, min: 0, max: 100, unit: '%', desc: 'How far world detail renders.' },
            ],
          },
          {
            key: 'audio', label: 'Audio', type: 'menu',
            desc: 'Master volume and voice chat.',
            items: [
              { key: 'volume', label: 'Master volume', type: 'slider', value: 70, min: 0, max: 100, unit: '%', desc: 'Overall game volume.' },
              { key: 'voice', label: 'Voice mode', type: 'select', value: 'Push to talk', options: ['Open mic', 'Push to talk', 'Muted'], desc: 'How your microphone transmits.' },
              { key: 'range', label: 'Talk range', type: 'range', value: 1, options: ['Whisper', 'Normal', 'Shout'], desc: 'Distance your voice carries.' },
            ],
          },
          { key: 'hud', label: 'Show HUD', type: 'check', value: true, desc: 'Toggle the entire heads-up display.' },
          { key: 'minimap', label: 'Show minimap', type: 'check', value: true, desc: 'Toggle the radar in the corner.' },
          { key: 'crosshair', label: 'Always crosshair', type: 'check', value: false, desc: 'Draw a crosshair even when not aiming.' },
          { key: 'nick', label: 'Display name', type: 'text', value: 'Kayla', desc: 'Name shown above your character.' },
          { key: 'reset', label: 'Reset to defaults', type: 'action', danger: true, desc: 'Restore every setting to stock values.' },
        ],
      },
      { key: 'inventory', label: 'Inventory', type: 'action', desc: 'Open your personal inventory.' },
      {
        key: 'emotes', label: 'Emotes', type: 'menu',
        desc: 'Animations, walk styles and props.',
        items: [
          { key: 'e1', label: 'Sit down', type: 'action', favorite: true },
          { key: 'e2', label: 'Lean', type: 'action' },
          { key: 'e3', label: 'Smoke', type: 'action', favorite: true },
          { key: 'e4', label: 'Handshake', type: 'action', right: 'NEARBY' },
          { key: 'e5', label: 'Surrender', type: 'action' },
        ],
      },
      { key: 'job', label: 'Clock in', type: 'action', right: 'OFF DUTY', desc: 'Start your shift at the current job site.' },
      { key: 'report', label: 'Report a player', type: 'action', desc: 'Submit a report to staff with a screenshot.' },
    ],
  }
}
