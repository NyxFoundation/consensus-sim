import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  base: './',
  test: {
    setupFiles: ['tests/setup/storage.ts'],
    // The UI tests drive whole attack runs through the real DOM: tens of
    // slots, each a full simulation step and re-render. That is far past the
    // 5 s default on a loaded machine, and slowness is not what any of them
    // assert, so give every test and hook the same generous budget.
    testTimeout: 30_000,
    hookTimeout: 30_000,
  },
})
