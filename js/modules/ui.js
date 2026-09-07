export function show(el) {
  if (!el) return
  el.classList.remove('hidden')
}

export function hide(el) {
  if (!el) return
  el.classList.add('hidden')
}

export function setText(el, text) {
  if (!el) return
  el.textContent = text
}

export function renderPlayerList(listEl, emptyEl, players, hostPlayerId, myPlayerId) {
  if (!listEl) return

  if (!players.length) {
    listEl.innerHTML = ''
    show(emptyEl)
    return
  }

  hide(emptyEl)
  listEl.innerHTML = players
    .map((player) => {
      const badges = []
      if (player.id === hostPlayerId) badges.push('Admin')
      if (player.id === myPlayerId) badges.push('Vos')
      const badgeHtml = badges
        .map((b) => `<span class="player-badge">${b}</span>`)
        .join('')

      return `<li class="player-row">
        <span class="body-text font-semibold">${escapeHtml(player.nickname)}</span>
        <span class="flex gap-2">${badgeHtml}</span>
      </li>`
    })
    .join('')
}

export function renderRevealList(listEl, roles) {
  if (!listEl) return
  listEl.innerHTML = roles
    .map((role) => {
      const label = role.isImpostor ? 'Impostor' : 'Civil'
      const tone = role.isImpostor ? 'reveal-impostor' : 'reveal-civil'
      return `<li class="${tone}">
        <span class="body-text font-semibold">${escapeHtml(role.nickname)}</span>
        <span class="caption ${role.isImpostor ? 'text-white/70' : ''}">${label}</span>
      </li>`
    })
    .join('')
}

export function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;')
}

export function poolLabel(count) {
  if (count === 1) return 'Hay 1 idea en el pozo'
  return `Hay ${count} ideas en el pozo`
}

export function winnerLabel(winner) {
  if (winner === 'impostors') return 'Ganó el impostor'
  if (winner === 'civilians') return 'Ganaron los civiles'
  return 'Fin de la ronda'
}
