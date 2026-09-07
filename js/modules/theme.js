const STORAGE_KEY = 'impostor.theme'

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
    const label = button.querySelector('[data-theme-label]')
    if (label) label.textContent = isDark ? 'Claro' : 'Oscuro'
  })
}

export function initThemeToggle() {
  applyTheme(getStoredTheme())
  document.querySelectorAll('[data-theme-toggle]').forEach((button) => {
    button.addEventListener('click', () => toggleTheme())
  })
}
