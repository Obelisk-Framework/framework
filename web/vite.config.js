import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import { fileURLToPath } from 'url'

// https://vite.dev/config/
export default defineConfig({
  plugins: [vue()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
      // plugins/modules live outside core/web, so Node's upward node_modules
      // walk from their files never reaches core/web/node_modules — alias
      // shared deps here explicitly instead of hoisting/duplicating installs.
      'dompurify': fileURLToPath(new URL('./node_modules/dompurify', import.meta.url))
    }
  },
  build: {
    rollupOptions: {
      output: {
        dir: '../core/html',
        format: 'es'
      }
    }
  }
})
