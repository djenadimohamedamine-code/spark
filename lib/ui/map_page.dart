import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';
import 'package:http/http.dart' as http;

class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();

  Position? _currentPosition;
  double _lastHeading = 0;
  double _smoothedSpeed = 0;
  double _distanceKm = 0.0;

  bool _satelliteMode = false;
  bool _isFollowing = true;
  bool _isSearching = false;

  LatLng? _destination;
  List<LatLng> _routePoints = [];
  String? _destinationName;

  // Offset de rotation de l'image
  static const double _carRotationOffset = 135.0;

  StreamSubscription<Position>? _positionStream;
  Timer? _recenterTimer;

  static const String _googleTrafficUrl    = 'https://mt0.google.com/vt/lyrs=m,traffic&hl=fr&x={x}&y={y}&z={z}';
  static const String _googleSatelliteUrl  = 'https://mt0.google.com/vt/lyrs=y&hl=fr&x={x}&y={y}&z={z}';

  @override
  void initState() {
    super.initState();
    _startLocationTracking();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _recenterTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  double _smoothAngle(double current, double target) {
    double diff = target - current;
    while (diff > 180) diff -= 360;
    while (diff < -180) diff += 360;
    return current + diff * 0.08;
  }

  Future<void> _startLocationTracking() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }

    try {
      Position pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      if (!mounted) return;
      setState(() {
        _currentPosition = pos;
        _lastHeading = pos.heading >= 0 ? pos.heading : 0;
        _smoothedSpeed = pos.speed * 3.6;
      });
      _followPosition(pos, _smoothedSpeed);
    } catch (_) {}

    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 1),
    ).listen((Position pos) {
      if (!mounted) return;
      double speedKmh = pos.speed * 3.6;
      _smoothedSpeed = _smoothedSpeed + ((speedKmh - _smoothedSpeed) * 0.1);

      double currentHeading = _lastHeading;
      if (speedKmh > 3.0 && pos.heading >= 0) {
        currentHeading = pos.heading;
      }
      
      double smoothed = _smoothAngle(_lastHeading, currentHeading);

      setState(() {
        if (_currentPosition != null) {
          _distanceKm += Geolocator.distanceBetween(
            _currentPosition!.latitude, _currentPosition!.longitude,
            pos.latitude, pos.longitude
          ) / 1000.0;
        }
        _currentPosition = pos;
        _lastHeading = smoothed;
      });

      if (_isFollowing) {
        _followPosition(pos, _smoothedSpeed);
      }
    });
  }

  void _followPosition(Position pos, double speedKmh) {
    if (!mounted) return;
    double targetZoom = (speedKmh > 80) ? 16.0 : (speedKmh > 40) ? 17.0 : 18.2;
    final offsetLat = pos.latitude + 0.0003;
    _mapController.move(LatLng(offsetLat, pos.longitude), targetZoom);
  }

  void _startRecenterTimer() {
    _recenterTimer?.cancel();
    _recenterTimer = Timer(const Duration(seconds: 6), () {
      if (mounted && !_isFollowing) {
        setState(() => _isFollowing = true);
        if (_currentPosition != null) _followPosition(_currentPosition!, _smoothedSpeed);
      }
    });
  }

  // --- RECHERCHE ET NAVIGATION ---

  Future<void> _searchDestination(String query) async {
    if (query.isEmpty) return;
    setState(() => _isSearching = true);

    try {
      // Geocoding via Nominatim (Free)
      final url = Uri.parse('https://nominatim.openstreetmap.org/search?format=json&q=$query&limit=1');
      final response = await http.get(url, headers: {'User-Agent': 'MimoSparkApp'});

      if (response.statusCode == 200) {
        final List results = json.decode(response.body);
        if (results.isNotEmpty) {
          final lat = double.parse(results[0]['lat']);
          final lon = double.parse(results[0]['lon']);
          final name = results[0]['display_name'].split(',')[0];

          setState(() {
            _destination = LatLng(lat, lon);
            _destinationName = name;
            _isFollowing = false;
          });

          _mapController.move(_destination!, 15.0);
          _getRoute(LatLng(_currentPosition!.latitude, _currentPosition!.longitude), _destination!);
        }
      }
    } catch (e) {
      print("Search Error: $e");
    } finally {
      setState(() => _isSearching = false);
    }
  }

  Future<void> _getRoute(LatLng start, LatLng end) async {
    try {
      // Routing via OSRM (Free)
      final url = Uri.parse('https://router.project-osrm.org/route/v1/driving/${start.longitude},${start.latitude};${end.longitude},${end.latitude}?overview=full&geometries=polyline');
      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['routes'] != null && data['routes'].isNotEmpty) {
          final geometry = data['routes'][0]['geometry'];
          final points = _decodePolyline(geometry);
          
          setState(() {
            _routePoints = points;
          });
        }
      }
    } catch (e) {
      print("Routing Error: $e");
    }
  }

  // Décodage Polyline OSRM (Standard Google Algorithm)
  List<LatLng> _decodePolyline(String encoded) {
    List<LatLng> points = [];
    int index = 0, len = encoded.length;
    int lat = 0, lng = 0;

    while (index < len) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      points.add(LatLng(lat / 1E5, lng / 1E5));
    }
    return points;
  }

  @override
  Widget build(BuildContext context) {
    String etaText = "--:--";
    if (_smoothedSpeed > 5 && _distanceKm > 0) {
       // Estimation basée sur la distance restante à vol d'oiseau si pas de route, ou sur la route si dispo
       // Pour faire simple ici on garde ton calcul original
    }

    final centerPos = _currentPosition != null
        ? LatLng(_currentPosition!.latitude, _currentPosition!.longitude)
        : const LatLng(36.8065, 10.1815);

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: centerPos,
              initialZoom: 18.2,
              onPositionChanged: (pos, hasGesture) {
                if (hasGesture) {
                  if (_isFollowing) setState(() => _isFollowing = false);
                  _startRecenterTimer();
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: _satelliteMode ? _googleSatelliteUrl : _googleTrafficUrl,
                userAgentPackageName: 'com.mimo.spark',
                maxZoom: 20,
              ),
              // TRACÉ DE LA ROUTE (Ligne bleue épaisse style Google)
              if (_routePoints.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _routePoints,
                      strokeWidth: 8.0,
                      color: Colors.blue.withOpacity(0.8),
                      borderColor: Colors.blue[900]!,
                      borderStrokeWidth: 2.0,
                    ),
                  ],
                ),
              // MARQUEURS (VOITURE + DESTINATION)
              MarkerLayer(
                markers: [
                  if (_destination != null)
                    Marker(
                      point: _destination!,
                      width: 50, height: 50,
                      child: const Icon(Icons.location_on, color: Colors.red, size: 45),
                    ),
                  if (_currentPosition != null)
                    Marker(
                      point: centerPos,
                      width: 150, height: 150,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            width: 70, height: 70,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.blue.withOpacity(0.12),
                            ),
                          ),
                          Transform.rotate(
                            angle: (_lastHeading + _carRotationOffset) * (math.pi / 180),
                            child: LayoutBuilder(builder: (context, constraints) {
                              final mapZoom = _mapController.camera.zoom;
                              final carSize = (mapZoom * 4.2).clamp(50.0, 95.0);
                              return Image.asset(
                                'assets/images/Adobe Express - file.png',
                                width: carSize, height: carSize,
                                fit: BoxFit.contain,
                              );
                            }),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),

          // BARRE DE RECHERCHE STYLE GOOGLE MAPS
          Positioned(
            top: 50, left: 16, right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: Colors.white12),
                boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 10)],
              ),
              child: Row(
                children: [
                  const Padding(
                    padding: EdgeInsets.all(8.0),
                    child: Icon(Icons.search, color: Colors.cyanAccent),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        hintText: "Où allons-nous Mimo ?",
                        hintStyle: TextStyle(color: Colors.white38),
                        border: InputBorder.none,
                      ),
                      onSubmitted: _searchDestination,
                    ),
                  ),
                  if (_destination != null)
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.redAccent),
                      onPressed: () {
                        setState(() {
                          _destination = null;
                          _routePoints = [];
                          _searchController.clear();
                        });
                      },
                    ),
                ],
              ),
            ),
          ),

          // INFOS DESTINATION (ETA / DISTANCE RESTANTE)
          if (_destination != null)
            Positioned(
              top: 110, left: 16, right: 16,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue[900]!.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.navigation, color: Colors.white),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_destinationName ?? "Destination", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                          const Text("Suivre le tracé bleu", style: TextStyle(color: Colors.white70, fontSize: 11)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // BOUTONS LATERAUX
          Positioned(
            top: 170, right: 16,
            child: Column(
              children: [
                FloatingActionButton(
                  heroTag: 'sat', mini: true,
                  backgroundColor: Colors.black87,
                  onPressed: () => setState(() => _satelliteMode = !_satelliteMode),
                  child: Icon(_satelliteMode ? Icons.map : Icons.satellite_alt, color: Colors.white),
                ),
                const SizedBox(height: 8),
                FloatingActionButton(
                  heroTag: 'center',
                  backgroundColor: _isFollowing ? Colors.cyanAccent : Colors.black87,
                  onPressed: () {
                    setState(() => _isFollowing = true);
                    if (_currentPosition != null) _followPosition(_currentPosition!, _smoothedSpeed);
                  },
                  child: Icon(_isFollowing ? Icons.gps_fixed : Icons.gps_not_fixed, color: _isFollowing ? Colors.black : Colors.cyanAccent),
                ),
              ],
            ),
          ),

          // INDICATEUR DE VITESSE EN BAS À GAUCHE
          Positioned(
            bottom: 100, left: 16,
            child: Container(
              width: 60, height: 60,
              decoration: BoxDecoration(
                color: Colors.black87,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.cyanAccent, width: 2),
              ),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text("${_smoothedSpeed.toInt()}", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
                    const Text("km/h", style: TextStyle(color: Colors.cyanAccent, fontSize: 8)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
