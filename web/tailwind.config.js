/** @type {import('tailwindcss').Config} */
export default {
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx,vue}",
    "../plugins/**/*.{js,ts,jsx,tsx,vue}",
    "../modules/**/*.{js,ts,jsx,tsx,vue}"
  ],
  theme: {
    extend: {
      // Wired to the :root custom properties in src/style.css — that file
      // is the single source of truth for values; this just exposes them
      // as bg-ob-accent / text-ob-accent / border-ob-border / etc. so new
      // plugin code can use ordinary Tailwind utilities instead of inline
      // style="color:var(--ob-accent)".
      colors: {
        ob: {
          accent: 'var(--ob-accent)',
          bg: 'var(--ob-bg)',
          panel: 'var(--ob-panel)',
          border: 'var(--ob-border)',
          text: 'var(--ob-text)',
          'text-dim': 'var(--ob-text-dim)',
        },
      },
    },
  },
  plugins: [],
}

