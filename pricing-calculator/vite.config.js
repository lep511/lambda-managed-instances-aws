// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0

import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// https://vite.dev/config
// Deployed via GitHub Pages
export default defineConfig(() => ({
  plugins: [react()],
  base: './',
  build: {
    outDir: 'dist',
  },
  server: {
    host: '0.0.0.0',
    port: 26159,
    allowedHosts: true,
  },
  preview: {
    host: '0.0.0.0',
    port: 26159,
    allowedHosts: true,
    headers: {
      'Cache-Control': 'no-cache, no-store, must-revalidate',
    },
  },
}))