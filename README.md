# BahnMap 🚆

An iOS app that shows every station and line you can ride with the **Deutschlandticket** (S-Bahn, RE, RB; no ICE/IC/FlixTrain) on one map, so you can see where you can go and plan the trip.

## Features

- **Network map**: about 8,000 regional stations and every regional line in Germany, coloured by type (S-Bahn green, RE red, RB blue). Search stations, show your location, tap a station.
- **Station boards**: departures and arrivals with platform, line and destination. Tap a train to see all its stops and draw it on the map.
- **"Where to?" (reachability)**: pick a station, a departure time and a time budget (15 min to 8 h). The map then shows every station you can reach, coloured by travel time, with a filter for direct trains only or a maximum number of changes. There's also a sorted list of destinations.
- **Connection search**: from/to, date and time, earlier and later options, direct-only filter, change times, and walking transfers between nearby stations. The detail view shows a map, every stop and the operator.
- **Works offline**: the whole timetable lives on the phone, and route planning runs on the device.
- Favourite stations, configurable minimum change time, and automatic weekly timetable updates.

## How it works

- **Data**: the free German regional rail GTFS feed from [GTFS.de](https://gtfs.de) (data © DELFI e.V., CC BY 4.0). The app downloads it (about 15 MB) and turns it into a compact binary timetable. It filters out trains the Deutschlandticket doesn't cover: long-distance, FlixTrain, night trains, heritage railways and international trains. See `GTFSImporter.DTicket`.
- **Routing**: the Connection Scan Algorithm (`BahnMap/Core/Router.swift`). A query takes a few milliseconds on about 600k daily connections.
- **UI**: SwiftUI with an MKMapView for the network map. iOS 17+.
- **Build**: [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`project.yml`) plus GitHub Actions on macOS (`.github/workflows/ios.yml`). No Mac needed.

Limitations: timetable data only, so no live delays or cancellations. The GTFS feed has no track geometry, so lines are drawn as straight segments between stations.

## Install on your iPhone

See **[docs/SETUP.md](docs/SETUP.md)**. Add 4 repository secrets (`APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`) and create the app in App Store Connect. After that, every push to `main` lands in TestFlight.

## Testing the engine without a Mac

The timetable engine (`BahnMap/Core`) is plain Swift and runs on Linux:

```bash
curl -LO https://download.gtfs.de/germany/rv_free/latest.zip
swift run -c release CoreCheck latest.zip
```

This imports the feed and prints sample departure boards, connections and reachability results.
