/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        // brand: air + trust (indigo/sky)
        brand: {
          50: '#eef2ff',
          100: '#e0e7ff',
          200: '#c7d2fe',
          300: '#a5b4fc',
          400: '#818cf8',
          500: '#6366f1',
          600: '#4f46e5',
          700: '#4338ca',
          800: '#3730a3',
          900: '#312e81',
        },
        // India NAQI semantic bands (shared by badge, chart, map)
        aqi: {
          good: '#22c55e',
          satisfactory: '#84cc16',
          moderate: '#eab308',
          poor: '#f97316',
          verypoor: '#ef4444',
          severe: '#9333ea',
        },
      },
      fontFamily: {
        sans: [
          'Inter',
          'Noto Sans Devanagari',
          'system-ui',
          '-apple-system',
          'Segoe UI',
          'Roboto',
          'sans-serif',
        ],
      },
      boxShadow: {
        card: '0 1px 2px rgba(16,24,40,.04), 0 1px 3px rgba(16,24,40,.08)',
        'card-lg': '0 4px 6px -1px rgba(16,24,40,.06), 0 10px 24px -4px rgba(16,24,40,.10)',
      },
      keyframes: {
        'fade-in': { from: { opacity: 0, transform: 'translateY(4px)' }, to: { opacity: 1, transform: 'none' } },
      },
      animation: {
        'fade-in': 'fade-in .3s ease-out',
      },
    },
  },
  plugins: [],
}
