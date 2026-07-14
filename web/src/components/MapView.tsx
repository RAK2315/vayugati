import maplibregl from 'maplibre-gl'
import 'maplibre-gl/dist/maplibre-gl.css'
import { useEffect, useRef } from 'react'

// Shared map for all three views. Phase 0: a placeholder centered on Delhi.
// Free demo basemap — swap for a proper style (e.g. MapTiler key) later.
const DELHI_CENTER: [number, number] = [77.209, 28.6139]
const STYLE_URL = 'https://demotiles.maplibre.org/style.json'

export default function MapView() {
  const containerRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!containerRef.current) return
    const map = new maplibregl.Map({
      container: containerRef.current,
      style: STYLE_URL,
      center: DELHI_CENTER,
      zoom: 9,
    })
    map.addControl(new maplibregl.NavigationControl(), 'top-right')
    return () => map.remove()
  }, [])

  return <div ref={containerRef} className="h-full w-full" />
}
