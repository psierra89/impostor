export const ROOM_THEMES = [
  {
    id: 'rosario',
    label: 'Rosario',
    blurb: 'Ciudad, bondis, picardía local',
    icon: 'bridge',
  },
  {
    id: 'futbol_ar_actual',
    label: 'Fútbol AR actual',
    blurb: 'Selección, clubes y la Scaloneta',
    icon: 'ball',
  },
  {
    id: 'futbol_ar_historico',
    label: 'Fútbol AR histórico',
    blurb: 'Diego, 86, ídolos de antes',
    icon: 'trophy',
  },
  {
    id: 'mundial',
    label: 'Mundial / Europa',
    blurb: 'Champions, cracks y clubes top',
    icon: 'globe',
  },
  {
    id: 'marcas',
    label: 'Marcas',
    blurb: 'Todos reciben una pista del tipo',
    icon: 'tag',
  },
]

export function themeMeta(id) {
  return ROOM_THEMES.find((t) => t.id === id) || ROOM_THEMES[0]
}

export function themeIconSvg(icon) {
  const common =
    'fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"'
  switch (icon) {
    case 'bridge':
      return `<svg viewBox="0 0 24 24" aria-hidden="true" ${common}><path d="M3 17V9l9-5 9 5v8"/><path d="M3 17h18"/><path d="M7 17v-4h10v4"/></svg>`
    case 'ball':
      return `<svg viewBox="0 0 24 24" aria-hidden="true" ${common}><circle cx="12" cy="12" r="9"/><path d="M12 3v18M3 12h18M7.5 5.5l9 13M16.5 5.5l-9 13"/></svg>`
    case 'trophy':
      return `<svg viewBox="0 0 24 24" aria-hidden="true" ${common}><path d="M8 21h8M12 17v4M7 4h10v5a5 5 0 0 1-10 0V4z"/><path d="M7 6H5a2 2 0 0 0 0 4h2M17 6h2a2 2 0 0 1 0 4h-2"/></svg>`
    case 'globe':
      return `<svg viewBox="0 0 24 24" aria-hidden="true" ${common}><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/></svg>`
    case 'tag':
      return `<svg viewBox="0 0 24 24" aria-hidden="true" ${common}><path d="M20 12l-8 8-9-9V3h8l9 9z"/><circle cx="7.5" cy="7.5" r="1.2" fill="currentColor" stroke="none"/></svg>`
    default:
      return `<svg viewBox="0 0 24 24" aria-hidden="true" ${common}><circle cx="12" cy="12" r="9"/></svg>`
  }
}
