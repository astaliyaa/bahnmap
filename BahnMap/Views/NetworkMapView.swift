import MapKit
import SwiftUI

final class StationAnnotation: NSObject, MKAnnotation {
    let index: Int32
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    let tint: UIColor
    let priority: Float
    let glyph: String

    init(index: Int32, coordinate: CLLocationCoordinate2D, title: String, subtitle: String?, tint: UIColor, priority: Float, glyph: String) {
        self.index = index
        self.coordinate = coordinate
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
        self.priority = priority
        self.glyph = glyph
    }
}

final class CategoryMultiPolyline: MKMultiPolyline {
    var category: LineCategory = .other
}

final class HighlightPolyline: MKPolyline {
    var color: UIColor = .systemPurple
    var dashed = false
}

struct NetworkMapView: UIViewRepresentable {
    var timetable: Timetable?
    var reach: Reachability?
    var reachMaxSeconds: Int32
    var highlight: Highlight?
    var focus: MapFocus?
    var showNetwork: Bool
    var onSelect: (Int32) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = true
        let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        config.pointOfInterestFilter = .excludingAll
        config.showsTraffic = false
        map.preferredConfiguration = config
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: Coordinator.reuseID)
        // Germany
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 51.2, longitude: 10.4),
                                         span: MKCoordinateSpan(latitudeDelta: 8.5, longitudeDelta: 8)), animated: false)
        LocationProvider.shared.request()
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.syncNetwork(map)
        c.syncHighlight(map)
        c.syncAnnotations(map, force: false)
        c.syncFocus(map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        static let reuseID = "station"
        var parent: NetworkMapView
        private var annotations: [Int32: StationAnnotation] = [:]
        private var modeKey = ""
        private var timetableID: ObjectIdentifier?
        private var networkOverlays: [MKOverlay] = []
        private var networkShown = false
        private var highlightID: UUID?
        private var highlightOverlays: [MKOverlay] = []
        private var focusID: UUID?
        private var byImportance: [Int32] = []

        init(_ parent: NetworkMapView) { self.parent = parent }

        // MARK: Network lines

        func syncNetwork(_ map: MKMapView) {
            guard let tt = parent.timetable else { return }
            let id = ObjectIdentifier(tt)
            if id != timetableID {
                timetableID = id
                map.removeOverlays(networkOverlays)
                networkOverlays = []
                networkShown = false
                byImportance = (0..<Int32(tt.stationCount)).filter { tt.importance[Int($0)] > 0 }
                    .sorted { tt.importance[Int($0)] > tt.importance[Int($1)] }
                var groups: [LineCategory: [MKPolyline]] = [:]
                for e in tt.edges {
                    var pts = [CLLocationCoordinate2D(latitude: tt.lat(e.a), longitude: tt.lon(e.a)),
                               CLLocationCoordinate2D(latitude: tt.lat(e.b), longitude: tt.lon(e.b))]
                    groups[e.category, default: []].append(MKPolyline(coordinates: &pts, count: 2))
                }
                // Draw the most important category last (on top).
                for cat in LineCategory.allCases.reversed() {
                    guard let lines = groups[cat] else { continue }
                    let multi = CategoryMultiPolyline(lines)
                    multi.category = cat
                    networkOverlays.append(multi)
                }
                modeKey = ""
            }
            if parent.showNetwork != networkShown {
                networkShown = parent.showNetwork
                if networkShown {
                    map.addOverlays(networkOverlays, level: .aboveRoads)
                } else {
                    map.removeOverlays(networkOverlays)
                }
            }
        }

        // MARK: Highlight

        func syncHighlight(_ map: MKMapView) {
            guard parent.highlight?.id != highlightID else { return }
            highlightID = parent.highlight?.id
            map.removeOverlays(highlightOverlays)
            highlightOverlays = []
            guard let h = parent.highlight else { return }
            for seg in h.segments {
                var pts = seg.coordinates
                let line = HighlightPolyline(coordinates: &pts, count: pts.count)
                line.color = seg.color
                line.dashed = seg.dashed
                highlightOverlays.append(line)
            }
            map.addOverlays(highlightOverlays, level: .aboveLabels)
        }

        // MARK: Focus

        func syncFocus(_ map: MKMapView) {
            guard let f = parent.focus, f.id != focusID else { return }
            focusID = f.id
            switch f.target {
            case let .station(s):
                guard let tt = parent.timetable else { return }
                let c = CLLocationCoordinate2D(latitude: tt.lat(s), longitude: tt.lon(s))
                let span = min(map.region.span.latitudeDelta, 0.6)
                // Shift the centre up a bit so the station is visible above the sheet.
                let center = CLLocationCoordinate2D(latitude: c.latitude - span * 0.22, longitude: c.longitude)
                map.setRegion(MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)), animated: true)
            case let .coordinates(coords):
                guard !coords.isEmpty else { return }
                var pts = coords
                let rect = MKPolyline(coordinates: &pts, count: pts.count).boundingMapRect
                map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 140, left: 40, bottom: 120, right: 40), animated: true)
            }
        }

        // MARK: Stations

        func syncAnnotations(_ map: MKMapView, force: Bool) {
            guard let tt = parent.timetable else { return }
            var key = "all"
            if let r = parent.reach { key = "reach-\(r.origin)-\(r.start)-\(parent.reachMaxSeconds)-\(r.arrival.hashValue)" }
            if key != modeKey {
                modeKey = key
                map.removeAnnotations(Array(annotations.values))
                annotations = [:]
            } else if !force {
                return
            }

            let region = map.region
            let span = region.span.latitudeDelta
            let latMin = region.center.latitude - region.span.latitudeDelta * 0.6
            let latMax = region.center.latitude + region.span.latitudeDelta * 0.6
            let lonMin = region.center.longitude - region.span.longitudeDelta * 0.6
            let lonMax = region.center.longitude + region.span.longitudeDelta * 0.6
            let limit: Int
            switch span {
            case 4...: limit = 90
            case 1.5..<4: limit = 180
            case 0.5..<1.5: limit = 300
            default: limit = 450
            }

            var wanted: [Int32] = []
            wanted.reserveCapacity(limit)
            let reach = parent.reach
            if let reach { wanted.append(reach.origin) }
            for s in byImportance {
                if wanted.count >= limit { break }
                let la = tt.lat(s), lo = tt.lon(s)
                guard la >= latMin, la <= latMax, lo >= lonMin, lo <= lonMax else { continue }
                if let reach, !reach.isReachable(s) || s == reach.origin { continue }
                wanted.append(s)
            }
            let wantedSet = Set(wanted)
            let selected = Set(map.selectedAnnotations.compactMap { ($0 as? StationAnnotation)?.index })
            var remove: [StationAnnotation] = []
            for (s, a) in annotations where !wantedSet.contains(s) && !selected.contains(s) {
                remove.append(a)
            }
            for a in remove { annotations[a.index] = nil }
            map.removeAnnotations(remove)

            let maxImp = Float(max(1, tt.importance[Int(byImportance.first ?? 0)]))
            var add: [StationAnnotation] = []
            for s in wanted where annotations[s] == nil {
                let imp = Float(tt.importance[Int(s)])
                var priority = 300 + 690 * (log(imp + 1) / log(maxImp + 1))
                var tint = UIColor(red: 0.2, green: 0.27, blue: 0.36, alpha: 1)
                var subtitle: String? = nil
                var glyph = "tram.fill"
                if let reach {
                    if s == reach.origin {
                        tint = .systemPurple
                        priority = 1000
                        glyph = "scope"
                        subtitle = "Start"
                    } else {
                        let dt = reach.arrival[Int(s)] - reach.start
                        let f = min(1, max(0, Double(dt) / Double(max(1, parent.reachMaxSeconds))))
                        tint = UIColor(hue: CGFloat(0.36 * (1 - f)), saturation: 0.85, brightness: 0.82, alpha: 1)
                        subtitle = ServiceClock.shortDuration(dt)
                    }
                }
                let a = StationAnnotation(index: s, coordinate: CLLocationCoordinate2D(latitude: tt.lat(s), longitude: tt.lon(s)),
                                          title: tt.name(s), subtitle: subtitle, tint: tint, priority: min(1000, priority), glyph: glyph)
                annotations[s] = a
                add.append(a)
            }
            map.addAnnotations(add)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            syncAnnotations(mapView, force: true)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let a = annotation as? StationAnnotation else { return nil }
            let v = mapView.dequeueReusableAnnotationView(withIdentifier: Self.reuseID, for: a)
            guard let m = v as? MKMarkerAnnotationView else { return v }
            m.markerTintColor = a.tint
            m.glyphImage = UIImage(systemName: a.glyph)
            m.displayPriority = MKFeatureDisplayPriority(rawValue: a.priority)
            m.titleVisibility = .adaptive
            m.subtitleVisibility = a.subtitle == nil ? .hidden : .visible
            m.animatesWhenAdded = false
            m.canShowCallout = false
            m.collisionMode = .circle
            return m
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            guard let a = annotation as? StationAnnotation else { return }
            parent.onSelect(a.index)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                mapView.deselectAnnotation(a, animated: false)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let h = overlay as? HighlightPolyline {
                let r = MKPolylineRenderer(polyline: h)
                r.strokeColor = h.color
                r.lineWidth = 6
                r.lineCap = .round
                r.lineJoin = .round
                if h.dashed { r.lineDashPattern = [4, 8] }
                return r
            }
            if let m = overlay as? CategoryMultiPolyline {
                let r = MKMultiPolylineRenderer(multiPolyline: m)
                r.strokeColor = m.category.uiColor.withAlphaComponent(m.category == .other ? 0.45 : 0.6)
                r.lineWidth = m.category == .sBahn || m.category == .regionalExpress ? 2.5 : 2
                r.lineCap = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
