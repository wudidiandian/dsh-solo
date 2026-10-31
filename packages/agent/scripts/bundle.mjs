/**
 * dsh-solo-agent 单文件打包脚本（2026-10-28）。
 *
 * 产物：dist/dsh-solo-agent.bundle.js —— 自包含 ESM bundle：
 *  - @dsh-solo/protocol（workspace 依赖）内联进产物，安装侧无需 monorepo
 *  - qrcode / ws 等运行时依赖一并内联（宿主环境无需 npm install）
 *  - cordis 保持 external：由 dsh 宿主提供，打进 bundle 反而会实例化第二套
 *    服务注册表（Node ESM 双实例坑，见 PROJECT_SUMMARY §12.3）
 *  - bufferutil / utf-8-validate 是 ws 的可选原生加速，标记 external 后
 *    运行时加载失败会自动回退纯 JS 实现
 *
 * 用法：npm run bundle （在 packages/agent 下）
 */
import { build } from 'esbuild'

await build({
  entryPoints: ['src/index.ts'],
  outfile: 'dist/dsh-solo-agent.bundle.js',
  banner: {
    // CJS 依赖（qrcode 等）在 ESM 产物里的 require('node:fs') 需要真实的
    // require 实现：用 createRequire 造一个，否则 "Dynamic require" 运行时炸
    js: `import { createRequire } from 'node:module'; const require = createRequire(import.meta.url);`,
  },
  bundle: true,
  platform: 'node',
  format: 'esm',
  target: 'node18',
  external: ['cordis', 'bufferutil', 'utf-8-validate'],
  sourcemap: false,
  minify: false,
  logLevel: 'info',
})
console.log('[bundle] dist/dsh-solo-agent.bundle.js OK')

await build({
  entryPoints: ['client/index.js'],
  outfile: 'dist/client.js',
  bundle: true,
  platform: 'browser',
  format: 'iife',
  target: 'es2022',
  sourcemap: false,
  logLevel: 'info',
})
