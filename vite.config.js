import { defineConfig } from 'vite'
import tailwindcss from '@tailwindcss/vite'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const rootDir = dirname(fileURLToPath(import.meta.url))

export default defineConfig({
  plugins: [
    tailwindcss(),
    {
      name: 'sala-code-rewrite',
      configureServer(server) {
        server.middlewares.use((req, _res, next) => {
          const url = req.url || ''
          const match = url.match(/^\/s\/([A-Za-z0-9]{6})\/?(\?.*)?$/)
          if (match) {
            const qs = match[2] ? `${match[2]}&code=${match[1]}` : `?code=${match[1]}`
            req.url = `/sala.html${qs}`
          }
          next()
        })
      },
    },
  ],
  build: {
    rollupOptions: {
      input: {
        main: resolve(rootDir, 'index.html'),
        sala: resolve(rootDir, 'sala.html'),
      },
    },
  },
  server: {
    port: 5173,
  },
})
