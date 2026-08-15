import { defineConfig } from 'vite'

/**
 * Bundles scripts/verify-engine.ts for Node so the engine port can be asserted without
 * adding a test-runner dependency. Used by `npm run verify:engine`.
 */
export default defineConfig({
  build: {
    ssr: true,
    outDir: 'node_modules/.verify',
    emptyOutDir: true,
    target: 'node22',
    rollupOptions: {
      input: 'scripts/verify-engine.ts',
      output: { entryFileNames: 'verify-engine.mjs', format: 'esm' },
    },
    minify: false,
    reportCompressedSize: false,
  },
})
