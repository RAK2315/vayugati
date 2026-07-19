import maplibregl from 'maplibre-gl'
import 'maplibre-gl/dist/maplibre-gl.css'
import { useEffect, useRef } from 'react'

const DELHI_CENTER: [number, number] = [77.209, 28.6139]
const STYLE_URL = 'https://demotiles.maplibre.org/style.json'

// hex colors matching the India NAQI AqiBadge scale
const AQI_COLORS: [number, string][] = [
  [50,  '#22c55e'],  // Good — green
  [100, '#84cc16'],  // Satisfactory — lime
  [200, '#eab308'],  // Moderate — yellow
  [300, '#f97316'],  // Poor — orange
  [400, '#ef4444'],  // Very Poor — red
]
const SEVERE_COLOR = '#9333ea'
const NO_DATA_COLOR = '#9ca3af'

function aqiColor(aqi: number | null): string {
  if (aqi === null) return NO_DATA_COLOR
  for (const [max, color] of AQI_COLORS) {
    if (aqi <= max) return color
  }
  return SEVERE_COLOR
}

export interface WardMarker {
  id: number
  name: string
  lat: number
  lng: number
  aqi: number | null
}

interface Props {
  markers?: WardMarker[]
  center?: [number, number]
  zoom?: number
}

export default function MapView({ markers = [], center, zoom = 9 }: Props) {
  const containerRef = useRef<HTMLDivElement>(null)
  const mapRef = useRef<maplibregl.Map | null>(null)

  useEffect(() => {
    if (!containerRef.current) return
    const map = new maplibregl.Map({
      container: containerRef.current,
      style: STYLE_URL,
      center: center ?? DELHI_CENTER,
      zoom,
    })
    map.addControl(new maplibregl.NavigationControl(), 'top-right')
    mapRef.current = map
    return () => {
      map.remove()
      mapRef.current = null
    }
  }, [])  // map instance created once

  // sync markers whenever they change (or map is ready)
  useEffect(() => {
    const map = mapRef.current
    if (!map || markers.length === 0) return

    const added: maplibregl.Marker[] = []

    const addMarkers = () => {
      for (const m of markers) {
        const el = document.createElement('div')
        const color = aqiColor(m.aqi)
        el.style.cssText = `
          width:28px;height:28px;border-radius:50%;
          background:${color};border:2px solid #fff;
          box-shadow:0 1px 4px rgba(0,0,0,.35);
          display:flex;align-items:center;justify-content:center;
          font-size:9px;font-weight:700;color:#fff;cursor:pointer;
        `
        el.textContent = m.aqi != null ? String(m.aqi) : '-'

        const popup = new maplibregl.Popup({ offset: 16, closeButton: false })
          .setHTML(
            `<div style="font-size:13px;font-weight:600">${m.name}</div>` +
            `<div style="font-size:12px;color:#555">AQI ${m.aqi ?? '-'}</div>`,
          )

        const marker = new maplibregl.Marker({ element: el })
          .setLngLat([m.lng, m.lat])
          .setPopup(popup)
          .addTo(map)
        added.push(marker)
      }
    }

    if (map.isStyleLoaded()) {
      addMarkers()
    } else {
      map.once('load', addMarkers)
    }

    return () => {
      added.forEach((m) => m.remove())
    }
  }, [markers])

  return <div ref={containerRef} className="h-full w-full" />
}
