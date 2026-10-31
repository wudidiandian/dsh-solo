import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vitest/config'

// 测试直接引用 protocol 源码，避免对构建产物的依赖
const here = path.dirname(fileURLToPath(import.meta.url))

export default defineConfig({
  test: {
    include: ['test/**/*.test.ts'],
    testTimeout: 20000,
  },
  resolve: {
    alias: {
      '@dsh-solo/protocol': path.resolve(here, '../protocol/src/index.ts'),
    },
  },
})
