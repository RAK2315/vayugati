"""Indian (CPCB) AQI sub-indices for PM2.5 and PM10, µg/m³."""

# (concentration_low, concentration_high, index_low, index_high)
PM25_BREAKPOINTS = [
    (0, 30, 0, 50),
    (30, 60, 51, 100),
    (60, 90, 101, 200),
    (90, 120, 201, 300),
    (120, 250, 301, 400),
    (250, 500, 401, 500),
]

PM10_BREAKPOINTS = [
    (0, 50, 0, 50),
    (50, 100, 51, 100),
    (100, 250, 101, 200),
    (250, 350, 201, 300),
    (350, 430, 301, 400),
    (430, 600, 401, 500),
]


def _sub_index(value: float, breakpoints: list[tuple]) -> int:
    if value <= 0:
        return 0
    for c_lo, c_hi, i_lo, i_hi in breakpoints:
        if value <= c_hi:
            return round(i_lo + (i_hi - i_lo) * (value - c_lo) / (c_hi - c_lo))
    return 500


def compute_aqi(pm25: float | None, pm10: float | None) -> int | None:
    """Max of the PM sub-indices. Other pollutants can be added later."""
    subs = []
    if pm25 is not None:
        subs.append(_sub_index(pm25, PM25_BREAKPOINTS))
    if pm10 is not None:
        subs.append(_sub_index(pm10, PM10_BREAKPOINTS))
    return max(subs) if subs else None
