/**
 * Mirrors core/shared/Settings.lua so date/number/currency formatting is
 * identical between Lua and the NUI. Fetches Settings.format once (cached
 * for the page's lifetime) via the core:client:getFormatSettings NUI
 * callback and falls back to the same defaults Settings.lua uses when
 * running outside FiveM (no window.invokeNative — see obelisk.js).
 */
import obelisk from '../obelisk.js'

const DEFAULTS = {
  dateFormat: 'YYYY-MM-DD',
  decimalSep: '.',
  thousandsSep: ',',
  currencySymbol: '$',
  currencyPosition: 'before',
  timezoneOffsetMinutes: 0,
}

let cached = null

export async function loadFormatSettings() {
  if (cached) return cached
  const format = await obelisk.emit('core:client:getFormatSettings', [])
  cached = { ...DEFAULTS, ...format }
  return cached
}

function tokens(format, epochSeconds) {
  const d = new Date((epochSeconds + format.timezoneOffsetMinutes * 60) * 1000)
  const pad = (n) => String(n).padStart(2, '0')
  return {
    YYYY: String(d.getUTCFullYear()).padStart(4, '0'),
    MM: pad(d.getUTCMonth() + 1),
    DD: pad(d.getUTCDate()),
    HH: pad(d.getUTCHours()),
    mm: pad(d.getUTCMinutes()),
    ss: pad(d.getUTCSeconds()),
  }
}

export function formatDate(epochSeconds, format = cached || DEFAULTS) {
  const t = tokens(format, epochSeconds)
  return format.dateFormat.replace(/YYYY|MM|DD|HH|mm|ss/g, (token) => t[token])
}

export function formatNumber(n, format = cached || DEFAULTS) {
  const sign = n < 0 ? '-' : ''
  const abs = Math.abs(n)
  const [intPart, fracPart] = abs.toFixed(2).split('.')
  const grouped = intPart.replace(/\B(?=(\d{3})+(?!\d))/g, format.thousandsSep)
  const useFrac = abs % 1 !== 0
  return sign + grouped + (useFrac ? format.decimalSep + fracPart : '')
}

export function formatCurrency(n, format = cached || DEFAULTS) {
  const formatted = formatNumber(n, format)
  return format.currencyPosition === 'after'
    ? formatted + format.currencySymbol
    : format.currencySymbol + formatted
}

export function useFormatSettings() {
  return { loadFormatSettings, formatDate, formatNumber, formatCurrency }
}
