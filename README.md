# Roamed for iOS

An iPhone app that quietly records where you go and burns the fog off a world map as you travel,
so you can see how much of the planet you have actually filled in.

Nothing leaves the phone. There is no account, no server and no analytics — the only network calls
are for map tiles and (optionally) naming the countries you pass through.

This is a port of [Roamed for Android](https://github.com/Jackque602/tracker-hardly-know-her). The
geometry, the fog rules, the atlas and the file formats are the same on both, deliberately and to
the byte: the same `regions.bin` is read by each, and a backup written on one restores on the other.
What differs is everything the platform decides — see [Differences from the Android
build](#differences-from-the-android-build).

## What it does

- **Fog of war map.** The whole world starts covered. Everywhere you have been is cut out of the
  fog, at roughly 300 m resolution, and stays cut out forever.
- **Background tracking.** "Always" location plus the location background mode keeps a subscription
  alive with the screen off, and significant-change monitoring relaunches the app if iOS terminates
  it. The blue status-bar indicator is the honest side of that bargain: it is always obvious when
  the app is recording.
- **Fit to everything.** One button frames the whole of what you have uncovered. It handles the
  antimeridian properly: if you have been to both Tokyo and San Francisco it wraps across the
  Pacific rather than zooming out to the whole planet the long way round.
- **Honest numbers.** Uncovered area in km², percentage of Earth's land and of the whole planet,
  distance travelled, days out, and how much new ground you broke each year.
- **Broken down by continent, country and state.** How much of each place you have actually
  covered, ranked, with the real share of each — 0.4% of Delaware reads as 0.4% of Delaware, not
  as a percentage of the planet. Worked out on the phone from a packaged atlas, so it needs no
  network and covers trips you imported as well as ones it watched.
- **And, in the United States, down to the county and the city.** Open a state and it shows the
  counties and cities inside it with the same honest share of each. Two more packaged atlases,
  still no network.
- **Flights, in blue.** Two fixes far enough apart and fast enough to have been a flight uncover
  the great circle between them — so a long-haul leg draws the arc it really flew, over Greenland
  rather than straight across the map. It counts towards every figure exactly as driven ground
  does; the blue tint and a separate flown-over total are there so you can still tell them apart.
- **Your data stays yours.** Export a full backup as JSON, the uncovered area as GeoJSON, or your
  trail as GPX. Import a backup to merge an old phone's map into this one — including an Android
  phone's.
- **Rescue a trip it missed.** Import a Google Maps Timeline export or a GPX from any other
  tracker, and the ground it covers gets uncovered as if the app had been watching. The Timeline
  reader is deliberately structural rather than tied to one schema, because Google has changed
  that file's shape several times.

## Building it

You need Xcode 16 or newer and an iPhone running iOS 17 or newer.

```bash
open Roamed.xcodeproj        # then ⌘R
swift test --package-path Core   # the maths, no simulator needed
```

The project is a single app target plus a local Swift package, `Core`, which Xcode resolves from
the checked-in path — there is nothing to fetch and no `pod install` step. `project.yml` is an
[XcodeGen](https://github.com/yonaskolb/XcodeGen) spec kept alongside the project as the readable
description of what it contains; the checked-in `Roamed.xcodeproj` is what actually builds, and
`xcodegen generate` is only there to rebuild it if it is ever damaged.

### Running it on your own phone

There is no App Store build and there is unlikely to be one: the app asks for always-on location
for something Apple would reasonably call a novelty, and the review conversation is not worth
having. Install it the way you would any app you built yourself — sign it with your own Apple ID in
Xcode's Signing & Capabilities and run it on your device. A free account's provisioning profile
expires after seven days, so a paid developer account is worth it if you intend to leave it
running; either way the app's data survives a reinstall of the same bundle identifier, and
**Settings → Export backup** survives anything.

Unlike the Android build, there is no signing-key trap here: iOS identifies an app by its bundle
identifier and provisioning, so rebuilding and reinstalling never wipes your map. The one thing
that does is deleting the app.

## How the fog actually works

The world is divided using the standard Web-Mercator tile grid at **zoom 17** — about 305 m across
at the equator, 195 m at 50° latitude. A cell is either uncovered or it is not; there is no partial
state. That single decision is what keeps a decade of tracking down to a few hundred thousand rows
instead of millions of GPS points.

When a fix arrives:

1. **Fixes that are too vague are dropped** (default: worse than 150 m accuracy).
2. **Jitter is ignored.** A stationary phone wanders tens of metres between readings. Until you have
   moved further than roughly the accuracy of the fix, the previous position stays the anchor, so
   the odometer does not climb while the phone sits on a table overnight.
3. **Every cell the accuracy circle touches is uncovered** — not just the one you stand in.
4. **Consecutive fixes are joined up.** At 100 km/h with a fix every 25 seconds you move 700 m
   between readings, so the segment between them is walked at half-cell steps and uncovered too.
   Gaps longer than 25 km, or longer than ten minutes, are treated as a flight, a tunnel or a
   glitch, and are *not* drawn — the map should not invent a line across the Atlantic.

Area is computed exactly rather than approximated: a Mercator cell is a lat/lon rectangle, whose
spherical area is `Δlon · R² · (sin φ_north − sin φ_south)`. Summing every cell in the grid
reconstructs the sphere between ±85.05° to within a rounding error, which is what `TileMathTests`
asserts.

**One caveat, stated plainly:** because a cell is all-or-nothing, walking 50 m down a street
uncovers a whole 300 m square. Uncovered area therefore flatters you at walking pace. It is
consistent, so progress over time is meaningful, but it is not a survey.

### Drawing it

The fog is one `MKOverlay` covering the world, and one blend mode: fill the tile with fog, then
erase the uncovered cells with `.clear`. Drawing the *holes* is what makes it cheap — there are
always far fewer uncovered cells on screen than pixels to cover.

`MKMapPoint` is Web Mercator scaled to 2²⁸ across, which is the same projection the fog grid uses,
so a stored cell at zoom z is exactly `2^(28 − z)` map points square. Turning a cell into something
MapKit can draw is a multiplication and nothing else — no trigonometry, no rounding, and no chance
of the fog drifting off the map it is covering.

Cells are drawn at their true size on the ground, so the cleared area shrinks as you zoom out
exactly like every other feature on the map. A city you have walked stays city-shaped at every zoom
rather than swelling into a square the size of a county.

Below about map zoom 10 a single cell is smaller than a pixel, so the index collapses cells to
whichever zoom keeps them around two points across — at that size, collapsing changes nothing you
can see. `ExploredIndex` keeps the set bucketed by z10 ancestor for zoomed-in queries and memoises
collapsed copies for zoomed-out ones, so the overlay gets a bounded list either way.

There is one further guard: if a single tile somehow contains more than 12,000 cells, the overlay
drops a zoom level rather than dropping frames. That takes an area so densely covered that the
coarser square is nearly full anyway, so it costs a point or two of accuracy and saves the frame
rate.

## Layout

```
Core/       A plain Swift package. Tile maths, the fog engine, the explored-cell index,
            statistics, the region atlas, the viewport arithmetic and the
            backup/GPX/GeoJSON formats. No UIKit, MapKit or CoreLocation, so it is
            unit-tested with `swift test` and needs no simulator.
Roamed/     Everything iOS: SQLite storage, the CoreLocation tracker, and a SwiftUI
            interface over an MKMapView.
tools/      The script that builds the region atlas from public boundary data. Run by
            hand; its output is committed, and is the same file the Android build ships.
```

Keeping the geometry in a separate package is deliberate, and is the same split the Android build
makes: the parts most likely to be subtly wrong are the parts that can be tested in a second.

## Flights

A transatlantic crossing uncovers well over a thousand square kilometres — several times what a
year of walking does. Flown ground is marked as its own thing from the moment it is recorded — a
`source` column on every cell, a blue wash on the map, its own line in the stats — but it counts
towards every figure the same as driven ground, the continent, country and state counts included.
Uncovered is uncovered; the tint is there to tell you how, not to dock you for it.

Recognising a flight is deliberately hard to trigger, because the cost of getting it wrong is a
great-circle ribbon hundreds of kilometres long across ground nobody visited. Two fixes count as a
flight only if they are **at least 150 km apart** *and* imply an average of **at least 90 m/s**
(324 km/h) *and* stay under the existing 305 m/s glitch ceiling. The competing explanation — the
tracker was suspended for an hour while you drove — fails that comfortably, because an hour of
driving covers a hundred kilometres, not a thousand. So does every scheduled train on earth, the
fastest of which averages about 270 km/h.

Two other rules keep it honest:

- **Ground beats air, always.** Land somewhere and the squares the flight painted around the
  airport are reclassified as travelled on your first fix there. It never goes the other way —
  flying over somewhere you have already walked should not restyle it as flown.
- **The great circle is the path.** Interpolating in flat lat/lon would run London to Los Angeles
  across the middle of the Atlantic. The tracer walks the sphere, so the arc goes where the
  aircraft goes.

Turn the whole thing off under Settings → Recording if you would rather flights left the map alone.

## Counting continents, countries and states

Working out which country a square is in would normally mean a point-in-polygon test against a few
million vertices, or a network call. Neither suits an app that has to do it for every square you
have ever uncovered, offline, while you scroll.

So the world's borders are drawn *once*, ahead of time, onto the very same Web Mercator grid the
fog uses — at z12, about 10 km per square — and stored run-length encoded, one row at a time. That
is `Core/Sources/RoamedCore/Resources/regions.bin`: 4,822 regions and about a megabyte, byte for
byte the file the Android build reads. A lookup is then a bit-shift to get from a fog square to an
atlas square and a binary search along one row.

Two consequences worth knowing:

- **Borders are only accurate to about 10 km.** Somewhere within a few kilometres of a state line
  can be credited to the wrong side of it. Nothing about the fog itself is affected — only which
  region its area is counted under.
- **Percentages are measured against true boundary areas, not against the grid.** If the
  denominator were the atlas squares, any region smaller than one square would read as fully
  explored the moment you clipped its corner. The generator computes each region's real geodesic
  area instead, and the displayed share is capped at 100% so a coarse coastline cannot push a small
  island past it.

Countries roll up into continents and states roll up into countries, so the three sets of numbers
nest. Russia is counted as Asia: the source data files all of it under Europe, which would hand
Europe thirteen million square kilometres of Siberia and make "how much of Europe have I seen"
meaningless. States are whatever each country calls its first-level divisions, which is why the
United States contributes fifty and the United Kingdom contributes two hundred and thirty-two.

Rebuilding the atlas (only needed to change the resolution or the source data):

```
python3 tools/build_region_mask.py --zoom 12 \
    --countries ne_50m_admin_0_countries.geojson \
    --subdivisions ne_10m_admin_1_states_provinces.geojson \
    --out Core/Sources/RoamedCore/Resources/regions.bin
```

## Counties and cities

Opening a state shows the counties and cities inside it. Those come from two further atlases, in
the same format and read by the same decoder, because neither tier fits in the first one.

**They are separate files because the resolutions have to differ.** A county is about 1,600 km²,
which is some twenty-nine squares of the z12 grid the world atlas uses — fine as it is. A city is
not: the median American urban footprint is 30 km², and a z12 square is 56 km². Drawn on that grid
a city would be handed every fog cell for miles around it and read as fully explored after one
drive past the airport. So cities get their own grid at z15, where a square is about 0.9 km² and a
median city is thirty-odd of them.

| | squares across | file | what it holds |
| --- | --- | --- | --- |
| `regions.bin` | z12 | 952 KiB | 7 continents, 242 countries, 4,573 states |
| `counties-us.bin` | z12 | 249 KiB | 3,143 US counties, parishes and boroughs |
| `cities-us.bin` | z15 | 96 KiB | 469 named US urban footprints |

`regions.bin` is deliberately left alone rather than grown a fourth tier. It is shared byte for
byte with the Android build, and that app's reader rejects region kinds it does not recognise — so
adding one would blank out its statistics entirely. The detail files instead repeat, inside
themselves, the states their localities belong to, carrying the same `US-PA`-style codes. That
code is the only thing the three files share; each numbers its own regions from zero.

Four things are worth knowing before reading the numbers:

- **The United States only, so far.** Counties come from the US Census and cities from Natural
  Earth's named places. Everywhere else a state simply has nothing underneath it, and shows no
  disclosure arrow rather than an empty one.
- **A city is its built-up footprint, not its city limits.** Natural Earth draws urban extent, so
  "Harrisburg" takes in the suburbs and comes to 396 km² rather than the 31 km² inside the city
  line. It is a real thing to measure and it is not the thing on the road sign.
- **Only the cities anyone would name.** The footprints themselves are anonymous — 11,878
  unnamed blobs — so each is named after the largest populated place sitting inside it. That
  yields the ones you would recognise, a median of nine per state, and none of the small towns.
- **A city that sprawls across a state line is cut at it.** Philadelphia's footprint reaches well
  into Delaware and New Jersey; left alone, walking around Christiana would have been credited to
  a Pennsylvania city, which is the same ground counted under two places that do not contain one
  another. The part in the next state along is counted there and not here, and the city's own area
  shrinks with it so it can still reach 100%.

Rebuilding them:

```
python3 tools/build_locality_mask.py counties --zoom 12 \
    --counties geojson-counties-fips.json \
    --subdivisions ne_10m_admin_1_states_provinces.geojson \
    --regions Core/Sources/RoamedCore/Resources/regions.bin \
    --out Core/Sources/RoamedCore/Resources/counties-us.bin

python3 tools/build_locality_mask.py cities --zoom 15 \
    --urban ne_10m_urban_areas.geojson \
    --places ne_10m_populated_places.geojson \
    --subdivisions ne_10m_admin_1_states_provinces.geojson \
    --regions Core/Sources/RoamedCore/Resources/regions.bin \
    --out Core/Sources/RoamedCore/Resources/cities-us.bin
```

## Differences from the Android build

Everything in `Core` is a faithful port, tested against the same assertions. Everything above it had
to be rebuilt on what iOS actually offers, and these are the places where the two apps genuinely
behave differently.

| | Android | iOS |
| --- | --- | --- |
| Map | OpenStreetMap tiles through osmdroid | MapKit |
| Background recording | A foreground service with a permanent notification | "Always" authorisation plus the `location` background mode, with significant-change monitoring to survive termination |
| Storage | Room | SQLite directly, same schema and same column names |
| Settings | DataStore | `UserDefaults` |
| Place names | `Geocoder` | `CLGeocoder` |
| Car screen | Android Auto | Not shipped — see below |
| Map styles | Standard, Topographic | Standard, Satellite, Hybrid |

**Why MapKit rather than OpenStreetMap.** The Android build points osmdroid at the public OSM tile
servers and identifies itself properly, as their usage policy requires. Doing the same here would
mean a second tile stack, a second disk cache and a second chance to get that policy wrong, for a
map that iOS already draws well and for free. If you would rather have OSM tiles, an `MKTileOverlay`
below the fog is about thirty lines — but read the [tile usage
policy](https://operations.osmfoundation.org/policies/tiles/) first, and point it at your own server
if the app is going to see any real use.

**Why there is no "check position every N seconds" in the same sense.** CoreLocation pushes fixes as
the hardware produces them rather than being polled. The interval setting throttles what the app
*accepts*, and "Only after moving" becomes the `distanceFilter`, which is what actually lets the
radio sleep. The two settings together do the same job as the Android pair; only the mechanism moved.

**Why there is no CarPlay screen.** Drawing a map on a car screen needs the
`com.apple.developer.carplay-maps` entitlement, which Apple grants by application and only to
navigation apps. It cannot be self-signed, so a sideloaded build cannot have one, and no amount of
code here changes that. The pixel arithmetic a car screen would need is nevertheless ported and
tested — `Viewport` in `Core`, with no MapKit in it — so if that entitlement ever arrives, the part
that is hard to check is already checked.

**Why the geocoder is asked even less often than on Android.** Apple rate-limits reverse geocoding
per app, and a tracker that asked on every fix would be throttled into uselessness within the hour.
It asks at most once per ~150 km square, and no more than once every thirty seconds. It is entirely
best effort: no network, no answer, no problem, and the country count is the only thing that misses
out.

## Settings worth knowing

| Setting | Default | What it trades |
| --- | --- | --- |
| Check position every | 25 s | Battery against how finely a fast journey is recorded |
| Only after moving | 20 m | The radio stays asleep while you sit still |
| Use GPS | on | Off leans on WiFi and cell towers, which cannot locate you away from towns |
| Reveal radius | 120 m | How generously a fix uncovers around itself |
| Ignore fixes worse than | 150 m | Rejecting rubbish fixes against missing indoor ones |
| Keep raw fixes for | 365 days | Storage. The uncovered map is kept forever regardless |

## Permissions

- **Location, "While Using the App"** — the entire point of the app. iOS insists this is asked for
  first and on its own.
- **Location, "Always"** — required to keep uncovering with the screen off. The app only offers this
  prompt once the first has been granted, because iOS silently ignores it otherwise.
- **Precise location** — without it the map fills in as a vague blur hundreds of metres wide, which
  is not a record of where you went.

There is no notification permission to grant: iOS shows the blue location indicator itself, and the
app asks for nothing else.

## Attribution

Map data is drawn by MapKit and is © Apple and its data providers.

Borders, country names, state names, urban footprints and city names come from
[Natural Earth](https://www.naturalearthdata.com), which is in the public domain.

US county boundaries come from the [US Census Bureau](https://www.census.gov/geographies/mapping-files/time-series/geo/cartographic-boundary.html)
cartographic boundary files, which are also in the public domain.
