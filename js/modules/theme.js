const STORAGE_KEY = 'impostor.theme'

const ICON_SUN = `<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41"/></svg>`
const ICON_MOON = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M21 14.5A8.5 8.5 0 0 1 9.5 3 7 7 0 1 0 21 14.5z"/></svg>`

export function getStoredTheme() {
  try {
    const value = localStorage.getItem(STORAGE_KEY)
    if (value === 'dark' || value === 'light') return value
  } catch {
    // ignore
  }
  return 'light'
}

export function applyTheme(theme) {
  const next = theme === 'dark' ? 'dark' : 'light'
  document.documentElement.classList.toggle('dark', next === 'dark')
  document.documentElement.dataset.theme = next
  const meta = document.querySelector('meta[name="theme-color"]')
  if (meta) meta.setAttribute('content', next === 'dark' ? '#000000' : '#ffffff')
  try {
    localStorage.setItem(STORAGE_KEY, next)
  } catch {
    // ignore
  }
  syncToggleButtons(next)
  return next
}

export function toggleTheme() {
  const current = document.documentElement.classList.contains('dark') ? 'dark' : 'light'
  return applyTheme(current === 'dark' ? 'light' : 'dark')
}

function syncToggleButtons(theme) {
  document.querySelectorAll('[data-theme-toggle]').forEach((button) => {
    const isDark = theme === 'dark'
    button.setAttribute('aria-pressed', String(isDark))
    button.setAttribute('aria-label', isDark ? 'Cambiar a modo claro' : 'Cambiar a modo oscuro')
    button.title = isDark ? 'Modo claro' : 'Modo oscuro'
    button.innerHTML = isDark ? ICON_SUN : ICON_MOON
  })
}

export function initThemeToggle() {
  applyTheme(getStoredTheme())
  document.querySelectorAll('[data-theme-toggle]').forEach((button) => {
    button.addEventListener('click', () => toggleTheme())
  })
}
