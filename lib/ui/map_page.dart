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

  // --- ÉLÉMENTS NAVIGATION AVANCÉS ---
  List<dynamic> _navigationSteps = [];
  int _currentStepIndex = 0;
  String _nextInstruction = "Suivez la route";
  double _distanceToNextStep = 0;
  IconData _nextManeuverIcon = Icons.navigation;
  DateTime? _lastRecalculateTime;

  // --- ÉLÉMENTS NAVIGATION AVANCÉS --- 

  StreamSubscription<Position>? _positionStream;

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
      if (_isFollowing) _followPosition(pos, _smoothedSpeed);
    } catch (_) {}

    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 1),
    ).listen((Position pos) {
      if (!mounted) return;
      double speedKmh = pos.speed * 3.6;
      _smoothedSpeed = _smoothedSpeed + ((speedKmh - _smoothedSpeed) * 0.1);

      double currentHeading = _lastHeading;
      // On baisse la limite à 1.5 km/h pour que la voiture tourne même à très faible allure
      if (speedKmh > 1.5) {
        if (pos.heading > 0.0) {
          currentHeading = pos.heading;
        } else if (_currentPosition != null) {
          // CALCUL MANUEL : Certains téléphones Android renvoient 0.0 pour le cap.
          // On le calcule nous-mêmes grâce à l'ancienne et la nouvelle position GPS.
          currentHeading = Geolocator.bearingBetween(
            _currentPosition!.latitude, _currentPosition!.longitude,
            pos.latitude, pos.longitude
          );
          if (currentHeading < 0) currentHeading += 360;
        }
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

      if (_destination != null && _routePoints.isNotEmpty) {
        _updateNavigation(pos);
      }

      if (_isFollowing) {
        _followPosition(pos, _smoothedSpeed);
      }
    });
  }

  void _followPosition(Position pos, double speedKmh) {
    if (!mounted) return;
    double targetZoom = (speedKmh > 80) ? 16.0 : (speedKmh > 40) ? 17.0 : 18.2;
    final offsetLat = pos.latitude + 0.0004;
    _mapController.move(LatLng(offsetLat, pos.longitude), targetZoom);
  }

  // --- RECHERCHE ET NAVIGATION ---

  Future<void> _searchDestination(String query) async {
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() => _isSearching = true);

    try {
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

          await _getRoute(LatLng(_currentPosition!.latitude, _currentPosition!.longitude), _destination!);
          _mapController.move(_destination!, 14.0);
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
      final url = Uri.parse('https://router.project-osrm.org/route/v1/driving/${start.longitude},${start.latitude};${end.longitude},${end.latitude}?overview=full&geometries=polyline&steps=true&languages=fr');
      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['routes'] != null && data['routes'].isNotEmpty) {
          final route = data['routes'][0];
          final geometry = route['geometry'];
          final points = _decodePolyline(geometry);
          
          setState(() {
            _routePoints = points;
            _navigationSteps = route['legs'][0]['steps'];
            _currentStepIndex = 0;
            _updateManeuverInfo();
            _isFollowing = true; 
          });
        }
      }
    } catch (e) {
      print("Routing Error: $e");
    }
  }

  LatLng _projectOnRoute(LatLng current, List<LatLng> route) {
    if (route.isEmpty) return current;
    LatLng closest = route.first;
    double minDist = double.infinity;
    for (final p in route) {
      final d = Geolocator.distanceBetween(current.latitude, current.longitude, p.latitude, p.longitude);
      if (d < minDist) { minDist = d; closest = p; }
    }
    return closest;
  }

  void _updateNavigation(Position currentPos) {
    if (_navigationSteps.isEmpty || _routePoints.isEmpty) return;

    final currentPoint = LatLng(currentPos.latitude, currentPos.longitude);
    final projected = _projectOnRoute(currentPoint, _routePoints);

    double distanceToRoute = Geolocator.distanceBetween(
      currentPoint.latitude, currentPoint.longitude,
      projected.latitude, projected.longitude
    );

    if (distanceToRoute > 70) {
      final now = DateTime.now();
      if (_lastRecalculateTime == null || now.difference(_lastRecalculateTime!).inSeconds > 12) {
        _lastRecalculateTime = now;
        _getRoute(currentPoint, _destination!);
        return;
      }
    }

    if (_currentStepIndex >= _navigationSteps.length) _currentStepIndex = _navigationSteps.length - 1;

    var currentStep = _navigationSteps[_currentStepIndex];
    var stepLocation = currentStep['maneuver']['location'];
    double distToStep = Geolocator.distanceBetween(
      currentPoint.latitude, currentPoint.longitude,
      stepLocation[1], stepLocation[0]
    );

    setState(() {
      _distanceToNextStep = distToStep;
    });

    if (distToStep < 25 && _currentStepIndex < _navigationSteps.length - 1) {
      setState(() {
        _currentStepIndex++;
        _updateManeuverInfo();
      });
    }
  }

  void _updateManeuverInfo() {
    if (_navigationSteps.isEmpty) return;
    var step = _navigationSteps[_currentStepIndex];
    setState(() {
      _nextInstruction = step['maneuver']['instruction'] ?? "Continuez";
      _nextManeuverIcon = _getManeuverIcon(step['maneuver']['type'], step['maneuver']['modifier'] ?? "");
    });
  }

  IconData _getManeuverIcon(String type, String modifier) {
    if (type.contains('turn')) {
      if (modifier.contains('left')) return Icons.turn_left;
      if (modifier.contains('right')) return Icons.turn_right;
    }
    if (type.contains('roundabout')) return Icons.rotate_right;
    if (type.contains('depart')) return Icons.play_arrow;
    if (type.contains('arrive')) return Icons.flag;
    return Icons.navigation;
  }

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
      shift = 0; result = 0;
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
                // Dès que l'utilisateur touche la carte, on arrête le suivi auto définitivement
                if (hasGesture && _isFollowing) {
                  setState(() => _isFollowing = false);
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: _satelliteMode ? _googleSatelliteUrl : _googleTrafficUrl,
                userAgentPackageName: 'com.mimo.spark',
                maxZoom: 20,
              ),
              if (_routePoints.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _routePoints,
                      strokeWidth: 12.0,
                      color: Colors.blue.withOpacity(0.9),
                      borderColor: Colors.blue[900]!,
                      borderStrokeWidth: 3.0,
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  if (_destination != null)
                    Marker(
                      point: _destination!,
                      width: 60, height: 60,
                      child: const Icon(Icons.location_on, color: Colors.red, size: 55),
                    ),
                  if (_currentPosition != null)
                    Marker(
                      point: centerPos,
                      width: 150, height: 150,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            width: 75, height: 75,
                            decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.blue.withOpacity(0.15)),
                          ),
                          Transform.rotate(
                            // +45.0 : Corrige le fait que l'image d'origine (PNG) est dessinée en diagonale (en haut à gauche)
                            // - rotation.camera garde la voiture sur la route même si on tourne la map
                            angle: (_lastHeading - _mapController.camera.rotation + 225.0) * (math.pi / 180),
                            child: LayoutBuilder(builder: (context, constraints) {
                              final mapZoom = _mapController.camera.zoom;
                              final carSize = (mapZoom * 4.5).clamp(55.0, 100.0);
                              return Image.asset('assets/images/Adobe Express - file.png', width: carSize, height: carSize);
                            }),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),

          // BANDEAU DE NAVIGATION
          if (_destination != null && _navigationSteps.isNotEmpty)
            Positioned(
              top: 40, left: 10, right: 10,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1B5E20),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 15)],
                ),
                child: Row(
                  children: [
                    Icon(_nextManeuverIcon, color: Colors.white, size: 50),
                    const SizedBox(width: 15),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _distanceToNextStep > 1000 
                              ? "${(_distanceToNextStep/1000).toStringAsFixed(1)} km" 
                              : "${_distanceToNextStep.toInt()} m",
                            style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w900),
                          ),
                          Text(_nextInstruction, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500), maxLines: 2),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // BOUTON RECENTRER GPS
          if (!_isFollowing)
            Positioned(
              bottom: _destination != null ? 100 : 30,
              right: 16,
              child: FloatingActionButton(
                heroTag: 'recenter',
                backgroundColor: const Color(0xFFFF3333),
                onPressed: () {
                  setState(() => _isFollowing = true);
                  if (_currentPosition != null) {
                    _followPosition(_currentPosition!, _smoothedSpeed);
                  }
                },
                child: const Icon(Icons.my_location, color: Colors.white),
              ),
            ),

          // BOUTON STOP NAVIGATION (uniquement quand une route est active)
          if (_destination != null)
            Positioned(
              bottom: 30, right: 16,
              child: FloatingActionButton(
                heroTag: 'stop', mini: true, backgroundColor: Colors.redAccent,
                onPressed: () => setState(() { _destination = null; _routePoints = []; _navigationSteps = []; }),
                child: const Icon(Icons.close, color: Colors.white),
              ),
            ),

          // COMPTEUR DE VITESSE
          Positioned(
            bottom: 30, left: 16,
            child: Container(
              width: 75, height: 75,
              decoration: BoxDecoration(color: Colors.black87, shape: BoxShape.circle, border: Border.all(color: const Color(0xFFFF3333), width: 3)),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text("${_smoothedSpeed.toInt()}", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 24)),
                    const Text("km/h", style: TextStyle(color: const Color(0xFFFF3333), fontSize: 10)),
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
