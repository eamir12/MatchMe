Geolocation Test Page

Location: web/test_geolocation.html

Purpose:
- Quick manual test page that continuously requests high-accuracy location (`enableHighAccuracy: true`) and shows raw vs smoothed (moving average) readings.

How to run locally:
- You must open the page from a secure origin. `http://localhost` is a secure context and will work; `file://` will not.

Windows (PowerShell):
```powershell
# from repository root
python -m http.server 8080
# then open in browser:
# http://localhost:8080/web/test_geolocation.html
```

Or with Node (if installed):
```bash
npx http-server -p 8080
# then open:
# http://localhost:8080/web/test_geolocation.html
```

Notes:
- Open Google Maps in a separate tab and compare the blue dot / accuracy ring with values shown on this page.
- If accuracy is poor (>50m): ensure OS location services are enabled, the browser has permission (and "Precise location" enabled), and the device can scan Wi‑Fi.
- The page logs recent raw readings and a moving-average filtered position. Use it to validate that continuous sampling (watchPosition) and smoothing improve stability.

If you want, I can:
- Add a small E2E test harness, or
- Integrate a more advanced Kalman smoother into this page for comparison.