import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  // `npm run dev` only: forward /api to a locally running API
  server: { proxy: { '/api': 'http://localhost:3000' } },
});
