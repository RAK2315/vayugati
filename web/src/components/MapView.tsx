import type { Feature, FeatureCollection, MultiPolygon, Polygon } from 'geojson'
import maplibregl, { type StyleSpecification } from 'maplibre-gl'
import 'maplibre-gl/dist/maplibre-gl.css'
import { useEffect, useRef } from 'react'
import { FALLBACK_STYLE } from '../lib/basemaps'
import { createMarkerElement, ensurePulseStyle, type MapMarker } from '../lib/mapMarkers'

export type { MapMarker, MapMarkerKind } from '../lib/mapMarkers'

const DELHI_CENTER: [number, number] = [77.209, 28.6139]

export interface WardBoundaryFeatureProps {
  id: number
  name: string
  wardNumber: number | null
}

const BOUNDARY_SOURCE_ID = 'ward-boundaries'
const BOUNDARY_FILL_LAYER_ID = 'ward-boundaries-fill'
const BOUNDARY_LINE_LAYER_ID = 'ward-boundaries-line'
const NO_SELECTION = -1 // sentinel: no real ward.id is ever <= 0 (serial starts at 1)

interface Props {
  markers?: MapMarker[]
  center?: [number, number]
  zoom?: number
  /** Basemap style URL or inline style spec - defaults to the keyless CARTO
   *  fallback, exactly the map's behaviour before the basemap switcher
   *  existed (just a nicer default style than the original MapLibre demo). */
  styleUrl?: string | StyleSpecification
  showScaleBar?: boolean
  onMarkerClick?: (marker: MapMarker) => void
  onHoverCoordinates?: (coords: { lng: number; lat: number } | null) => void
  /** [lng, lat] pairs to fit the viewport to - e.g. "Reset view"/"Fit to city". */
  fitBoundsTo?: [number, number][]
  /** Real ward boundary polygons (Supabase `wards.boundary`, Phase 2 import)
   *  - never hardcoded. Omitted/empty means nothing to draw; the layer
   *    control already reflects that by disabling the toggle (MapPage.tsx). */
  wardBoundaries?: FeatureCollection<Polygon | MultiPolygon, WardBoundaryFeatureProps>
  showWardBoundaries?: boolean
  selectedBoundaryId?: number | null
  onBoundaryClick?: (ward: WardBoundaryFeatureProps) => void
}

/**
 * Shared map canvas - embedded bare (no props) by CitizenView.tsx/FieldView.tsx
 * as a small context map, and with the full prop set by MapPage.tsx's spatial
 * console. Every prop here is optional and additive: omitting all of them
 * reproduces the exact behaviour this component had before the Map page
 * redesign, so the two bare embeds are unaffected.
 */
export default function MapView({
  markers = [],
  center,
  zoom = 9,
  styleUrl,
  showScaleBar = false,
  onMarkerClick,
  onHoverCoordinates,
  fitBoundsTo,
  wardBoundaries,
  showWardBoundaries = false,
  selectedBoundaryId = null,
  onBoundaryClick,
}: Props) {
  const containerRef = useRef<HTMLDivElement>(null)
  const mapRef = useRef<maplibregl.Map | null>(null)

  // Ward-boundary GL layers are wiped by every setStyle() call (unlike the
  // DOM-based markers below, which survive it) and are read from inside
  // event callbacks registered once at map creation - both need the latest
  // values without re-registering listeners, hence refs kept in sync here.
  const wardBoundariesRef = useRef(wardBoundaries)
  const showWardBoundariesRef = useRef(showWardBoundaries)
  const selectedBoundaryIdRef = useRef(selectedBoundaryId)
  const onBoundaryClickRef = useRef(onBoundaryClick)
  // Set once inside the mount effect below (it needs `map`, only available
  // there) - the wardBoundaries-change effect calls it too, so a fresh
  // arrival of data can create the source/layers for the first time, not
  // just update one that (incorrectly) assumed to already exist.
  const ensureBoundaryLayersRef = useRef<(() => void) | null>(null)
  useEffect(() => {
    wardBoundariesRef.current = wardBoundaries
  }, [wardBoundaries])
  useEffect(() => {
    showWardBoundariesRef.current = showWardBoundaries
  }, [showWardBoundaries])
  useEffect(() => {
    selectedBoundaryIdRef.current = selectedBoundaryId
  }, [selectedBoundaryId])
  useEffect(() => {
    onBoundaryClickRef.current = onBoundaryClick
  }, [onBoundaryClick])

  useEffect(() => {
    ensurePulseStyle()
    if (!containerRef.current) return
    const map = new maplibregl.Map({
      container: containerRef.current,
      style: styleUrl ?? FALLBACK_STYLE,
      center: center ?? DELHI_CENTER,
      zoom,
    })
    map.addControl(new maplibregl.NavigationControl(), 'top-right')
    if (showScaleBar) map.addControl(new maplibregl.ScaleControl({ unit: 'metric' }), 'bottom-right')
    if (onHoverCoordinates) {
      map.on('mousemove', (e) => onHoverCoordinates({ lng: e.lngLat.lng, lat: e.lngLat.lat }))
      map.on('mouseout', () => onHoverCoordinates(null))
    }

    // Delegated listeners on the boundary fill layer - registered once, up
    // front. MapLibre only dispatches these once a layer with this id
    // actually exists, so this is safe even before the layer is first added
    // (initial data load) and keeps working across every later setStyle().
    map.on('click', BOUNDARY_FILL_LAYER_ID, (e) => {
      const feature = e.features?.[0] as Feature<Polygon | MultiPolygon, WardBoundaryFeatureProps> | undefined
      if (feature) onBoundaryClickRef.current?.(feature.properties)
    })
    map.on('mouseenter', BOUNDARY_FILL_LAYER_ID, () => {
      map.getCanvas().style.cursor = 'pointer'
    })
    map.on('mouseleave', BOUNDARY_FILL_LAYER_ID, () => {
      map.getCanvas().style.cursor = ''
    })

    const addBoundaryLayers = () => {
      const data = wardBoundariesRef.current
      if (!data) return
      const existingSource = map.getSource(BOUNDARY_SOURCE_ID) as maplibregl.GeoJSONSource | undefined
      if (existingSource) {
        existingSource.setData(data)
        return
      }
      map.addSource(BOUNDARY_SOURCE_ID, { type: 'geojson', data })
      const visibility = showWardBoundariesRef.current ? 'visible' : 'none'
      const selectedId = selectedBoundaryIdRef.current ?? NO_SELECTION
      map.addLayer({
        id: BOUNDARY_FILL_LAYER_ID,
        type: 'fill',
        source: BOUNDARY_SOURCE_ID,
        layout: { visibility },
        paint: {
          'fill-color': '#0ea5e9',
          'fill-opacity': ['case', ['==', ['get', 'id'], selectedId], 0.35, 0.08],
        },
      })
      map.addLayer({
        id: BOUNDARY_LINE_LAYER_ID,
        type: 'line',
        source: BOUNDARY_SOURCE_ID,
        layout: { visibility },
        paint: {
          'line-color': '#0ea5e9',
          'line-width': ['case', ['==', ['get', 'id'], selectedId], 2.5, 1],
        },
      })
    }
    ensureBoundaryLayersRef.current = addBoundaryLayers
    if (map.isStyleLoaded()) addBoundaryLayers()
    else map.once('load', addBoundaryLayers)
    // Every basemap swap (see the styleUrl effect below) wipes all custom
    // sources/layers - 'style.load' fires once per setStyle() completion
    // (unlike 'load', which is a one-time map-lifecycle event), so this
    // keeps the boundary layer alive across basemap switching.
    map.on('style.load', addBoundaryLayers)

    mapRef.current = map
    return () => {
      map.remove()
      mapRef.current = null
    }
    // Map instance created once - style/bounds/boundary-data changes are
    // handled by their own effects below rather than tearing down and
    // recreating the map.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // Basemap swap on an already-live map - markers are DOM overlays
  // independent of the style, so they persist across setStyle() untouched.
  useEffect(() => {
    const map = mapRef.current
    if (!map || !styleUrl) return
    if (map.isStyleLoaded()) map.setStyle(styleUrl)
    else map.once('load', () => map.setStyle(styleUrl))
  }, [styleUrl])

  useEffect(() => {
    const map = mapRef.current
    if (!map || !fitBoundsTo || fitBoundsTo.length === 0) return
    const bounds = fitBoundsTo.reduce(
      (b, coord) => b.extend(coord),
      new maplibregl.LngLatBounds(fitBoundsTo[0], fitBoundsTo[0]),
    )
    // minZoom is defense in depth on top of MapPage's own coordinate
    // validation - a bad point should never be able to zoom this out past
    // city scale, even in theory.
    map.fitBounds(bounds, { padding: 56, minZoom: 9, maxZoom: 13, duration: 600 })
  }, [fitBoundsTo])

  // sync markers whenever they change (or map is ready)
  useEffect(() => {
    const map = mapRef.current
    if (!map || markers.length === 0) return

    // If the style isn't loaded yet, marker creation is deferred to the
    // 'load' event via map.once() below. If `markers` changes again before
    // that fires (very likely - MapPage.tsx's staggered async fetches
    // change `allMarkers`'s reference shortly after mount), React calls
    // THIS cleanup while addedMarkers/addedPopups are still empty (nothing
    // to remove yet), leaving the original once('load', addMarkers)
    // registration orphaned - it still fires later and adds a full "ghost"
    // generation of markers nothing can ever clean up. `cancelled` +
    // map.off() below close that race.
    let cancelled = false
    const addedMarkers: maplibregl.Marker[] = []
    const addedPopups: maplibregl.Popup[] = []

    const addMarkers = () => {
      if (cancelled) return
      for (const m of markers) {
        const el = createMarkerElement(m)
        const marker = new maplibregl.Marker({ element: el }).setLngLat([m.lng, m.lat]).addTo(map)
        // Popup is managed manually (not via marker.setPopup()) so hover
        // (preview) and click (select, via onMarkerClick) stay independent
        // instead of both fighting over the marker's built-in click-toggle.
        const popup = new maplibregl.Popup({ offset: 16, closeButton: false })
          .setLngLat([m.lng, m.lat])
          .setHTML(m.popupHtml)

        el.addEventListener('mouseenter', () => popup.addTo(map))
        el.addEventListener('mouseleave', () => popup.remove())
        el.addEventListener('click', () => onMarkerClick?.(m))

        addedMarkers.push(marker)
        addedPopups.push(popup)
      }
    }

    if (map.isStyleLoaded()) addMarkers()
    else map.once('load', addMarkers)

    return () => {
      cancelled = true
      map.off('load', addMarkers)
      addedMarkers.forEach((m) => m.remove())
      addedPopups.forEach((p) => p.remove())
    }
  }, [markers, onMarkerClick])

  // Push new/changed boundary data - creates the source/layers fresh if
  // this is their first arrival (MapPage.tsx's fetch resolves
  // asynchronously after mount, same staggered-load pattern as markers
  // above, so the mount effect above almost always runs before any real
  // data exists), or just updates them via setData if they already exist.
  useEffect(() => {
    const map = mapRef.current
    if (!map || !wardBoundaries) return
    const apply = () => ensureBoundaryLayersRef.current?.()
    if (map.isStyleLoaded()) apply()
    else map.once('load', apply)
  }, [wardBoundaries])

  // Toggle layer visibility without touching the source/data.
  useEffect(() => {
    const map = mapRef.current
    if (!map) return
    const visibility = showWardBoundaries ? 'visible' : 'none'
    const apply = () => {
      if (map.getLayer(BOUNDARY_FILL_LAYER_ID)) map.setLayoutProperty(BOUNDARY_FILL_LAYER_ID, 'visibility', visibility)
      if (map.getLayer(BOUNDARY_LINE_LAYER_ID)) map.setLayoutProperty(BOUNDARY_LINE_LAYER_ID, 'visibility', visibility)
    }
    if (map.isStyleLoaded()) apply()
    else map.once('load', apply)
  }, [showWardBoundaries])

  // Highlight the selected ward's polygon without touching the source/data.
  useEffect(() => {
    const map = mapRef.current
    if (!map) return
    const id = selectedBoundaryId ?? NO_SELECTION
    const apply = () => {
      if (!map.getLayer(BOUNDARY_FILL_LAYER_ID)) return
      map.setPaintProperty(BOUNDARY_FILL_LAYER_ID, 'fill-opacity', ['case', ['==', ['get', 'id'], id], 0.35, 0.08])
      map.setPaintProperty(BOUNDARY_LINE_LAYER_ID, 'line-width', ['case', ['==', ['get', 'id'], id], 2.5, 1])
    }
    if (map.isStyleLoaded()) apply()
    else map.once('load', apply)
  }, [selectedBoundaryId])

  return <div ref={containerRef} className="h-full w-full" />
}
