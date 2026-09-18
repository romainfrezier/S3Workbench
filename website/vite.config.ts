import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react(), {
    name: 'development-entry',
    apply: 'serve',
    transformIndexHtml() {
      return [{ tag: 'script', attrs: { type: 'module', src: '/src/main.tsx' }, injectTo: 'body' }]
    },
  }],
  build: { ssrEmitAssets: true, modulePreload: false },
  base: process.env.VITE_BASE_PATH || '/',
})
