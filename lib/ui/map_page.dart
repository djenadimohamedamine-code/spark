import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:async';
import '../core/vehicle_marker_heading.dart';
import '../core/gps_heading_tracker.dart';
import '../core/gps_route_geometry.dart';
import '../core/gps_debug_logger.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final MapController _mapController = MapController();

  Position? _currentPosition;
  double _lastHeading = 0;
  final GpsHeadingTracker _headingTracker = GpsHeadingTracker();
  double _smoothedSpeed = 0;

  bool _satelliteMode = false;
  int _tileRefreshVersion = 0;
  DateTime? _tileErrorWindowStart;
  int _tileErrorsInWindow = 0;
  bool _tileRetryVisible = false;
  bool _isFollowing = true;
  Timer? _autoResumeFollowingTimer;
  static const Duration _followRecoveryDelay = Duration(seconds: 12);

  LatLng? _destination;
  List<LatLng> _routePoints = [];

  // --- ÉLÉMENTS NAVIGATION AVANCÉS ---
  List<dynamic> _navigationSteps = [];
  int _currentStepIndex = 0;
  String _nextInstruction = "Suivez la route";
  double _distanceToNextStep = 0;
  IconData _nextManeuverIcon = Icons.navigation;
  DateTime? _lastRecalculateTime;
  final GpsRouteRequestGuard _routeRequestGuard = GpsRouteRequestGuard();

  // --- ÉLÉMENTS NAVIGATION AVANCÉS --- 

  StreamSubscription<Position>? _positionStream;

  // Public key-free sources. Neither contains real-time traffic data.
  static const String _osmTileUrl =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String _esriSatelliteUrl =
      'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';

  @override
  void initState() {
    super.initState();
    GpsDebugLogger.init();
    _startLocationTracking();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _autoResumeFollowingTimer?.cancel();
    _routeRequestGuard.invalidate();
    GpsDebugLogger.close();
    super.dispose();
  }

  bool _hasValidCoordinates(Position position) => GpsFix(
    latitude: position.latitude,
    longitude: position.longitude,
    speedKmh: 0,
    headingDegrees: 0,
    accuracyMeters: position.accuracy,
  ).hasValidCoordinates;

  GpsHeadingUpdate _trackHeading(Position position) {
    final rawSpeedKmh = position.speed * 3.6;
    final speedKmh = rawSpeedKmh.isFinite && rawSpeedKmh > 0
        ? rawSpeedKmh : 0.0;
    return _headingTracker.update(GpsFix(
      latitude: position.latitude,
      longitude: position.longitude,
      speedKmh: speedKmh,
      headingDegrees: position.heading,
      accuracyMeters: position.accuracy,
    ));
  }

  Future<void> _startLocationTracking() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }

    if (permission == LocationPermission.deniedForever) return;
    try {
      Position pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      if (!mounted) return;
      if (!_hasValidCoordinates(pos)) {
        throw const FormatException('Invalid initial GPS coordinates');
      }
      setState(() {
        _currentPosition = pos;
        _lastHeading = _trackHeading(pos).headingDegrees;
        _smoothedSpeed = (pos.speed.isFinite && pos.speed > 0)
            ? pos.speed * 3.6 : 0;
      });
      if (_isFollowing) _followPosition(pos, _smoothedSpeed);
    } catch (_) {}

    if (!mounted) return;
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 1),
    ).listen((Position pos) {
      if (!mounted || !_hasValidCoordinates(pos)) return;
      final rawSpeedKmh = pos.speed * 3.6;
      final speedKmh = rawSpeedKmh.isFinite && rawSpeedKmh > 0
          ? rawSpeedKmh : 0.0;
      _smoothedSpeed += (speedKmh - _smoothedSpeed) * 0.1;
      final headingUpdate = _trackHeading(pos);

      if (GpsDebugLogger.enabled) {
        GpsDebugLogger.log(
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          speedKmh: speedKmh,
          headingRaw: pos.heading,
          accuracyM: pos.accuracy,
          distPrevM: headingUpdate.stepMeters,
          distAnchorM: headingUpdate.anchorMeters,
          source: headingUpdate.source,
          smoothedDeg: headingUpdate.headingDegrees,
          page: 'MapPage',
        );
      }


      setState(() {
        _currentPosition = pos;
        _lastHeading = headingUpdate.headingDegrees;
      });

      if (_destination != null && _routePoints.isNotEmpty) {
        _updateNavigation(pos);
      }

      if (_isFollowing) {
        _followPosition(pos, _smoothedSpeed);
      }
    }, onError: (Object error) {
      debugPrint('GPS MapPage: erreur flux localisation : $error');
    });
  }

  void _followPosition(Position pos, double speedKmh) {
    if (!mounted) return;
    double targetZoom = (speedKmh > 80) ? 16.0 : (speedKmh > 40) ? 17.0 : 18.2;
    // A fixed northward offset misplaces the car when heading south.
    _mapController.move(LatLng(pos.latitude, pos.longitude), targetZoom);
  }

  // Après un déplacement manuel, ne pas laisser le suivi GPS désactivé
  // indéfiniment : l'utilisateur retrouve sa voiture automatiquement.
  // Un nouveau geste repousse le délai pour ne pas gêner l'exploration.
  void _pauseFollowingForGesture() {
    if (!_isFollowing && _autoResumeFollowingTimer == null) return;
    if (_isFollowing) {
      setState(() => _isFollowing = false);
      if (GpsDebugLogger.enabled) GpsDebugLogger.mark('AUTO_FOLLOW_PAUSED');
    }
    _autoResumeFollowingTimer?.cancel();
    _autoResumeFollowingTimer = Timer(_followRecoveryDelay, () {
      if (!mounted) return;
      _resumeFollowing();
    });
  }

  void _onMapTileError() {
    if (!mounted || _tileRetryVisible) return;
    final now = DateTime.now();
    if (_tileErrorWindowStart == null ||
        now.difference(_tileErrorWindowStart!) > const Duration(seconds: 20)) {
      _tileErrorWindowStart = now;
      _tileErrorsInWindow = 0;
    }
    _tileErrorsInWindow++;
    if (_tileErrorsInWindow == 3) {
      if (GpsDebugLogger.enabled) GpsDebugLogger.mark('MAP_TILES_DOWNLOAD_FAILED');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _tileRetryVisible) return;
        setState(() => _tileRetryVisible = true);
      });
    }
  }

  void _refreshMapTiles({bool toggleSatellite = false}) {
    setState(() {
      if (toggleSatellite) _satelliteMode = !_satelliteMode;
      _tileRefreshVersion++;
      _tileRetryVisible = false;
      _tileErrorsInWindow = 0;
      _tileErrorWindowStart = null;
    });
    if (GpsDebugLogger.enabled) GpsDebugLogger.mark('MAP_TILES_MANUAL_REFRESH');
  }

  void _resumeFollowing() {
    _autoResumeFollowingTimer?.cancel();
    _autoResumeFollowingTimer = null;
    if (!_isFollowing) {
      setState(() => _isFollowing = true);
      if (GpsDebugLogger.enabled) GpsDebugLogger.mark('AUTO_FOLLOW_RESUMED');
    }
    final fix = _currentPosition;
    if (fix != null) _followPosition(fix, _smoothedSpeed);
  }

  void _chooseDestination(LatLng destination) {
    if (_currentPosition == null) return;
    _autoResumeFollowingTimer?.cancel();
    _autoResumeFollowingTimer = null;
    setState(() {
      _destination = destination;
      _routePoints = [];
      _navigationSteps = [];
      _currentStepIndex = 0;
      _lastRecalculateTime = null;
      _isFollowing = true;
    });
    _getRoute(
      LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
      destination,
    );
  }

  Future<void> _getRoute(LatLng start, LatLng end) async {
    final requestId = _routeRequestGuard.begin();
    try {
      final url = Uri.parse('https://router.project-osrm.org/route/v1/driving/${start.longitude},${start.latitude};${end.longitude},${end.latitude}?overview=full&geometries=polyline&steps=true&languages=fr');
      final response = await http.get(url).timeout(const Duration(seconds: 12));
      if (!mounted || !_routeRequestGuard.isCurrent(requestId)) return;
      final destination = _destination;
      if (destination == null ||
          destination.latitude != end.latitude ||
          destination.longitude != end.longitude) return;

      if (response.statusCode != 200) {
        debugPrint('GPS routing: HTTP ${response.statusCode}');
        return;
      }

      final data = json.decode(response.body);
      if (data['routes'] == null || data['routes'].isEmpty) return;
      final route = data['routes'][0];
      final points = _decodePolyline(route['geometry'] as String);
      final steps = route['legs'][0]['steps'] as List<dynamic>;
      if (points.isEmpty || steps.isEmpty) return;

      setState(() {
        _routePoints = points;
        _navigationSteps = steps;
        _currentStepIndex = 0;
        _distanceToNextStep = 0;
        _updateManeuverInfo();
      });
    } catch (error) {
      if (mounted && _routeRequestGuard.isCurrent(requestId)) {
        debugPrint('GPS routing: impossible de calculer la route : $error');
      }
    }
  }

  void _updateNavigation(Position currentPos) {
    if (_navigationSteps.isEmpty || _routePoints.isEmpty) return;

    final currentPoint = LatLng(currentPos.latitude, currentPos.longitude);
    // Le GPS peut être loin des sommets tout en étant SUR la route.
    final distanceToRoute = GpsRouteGeometry.distanceMetersToPolyline(
      currentPoint, _routePoints,
    );

    if (distanceToRoute > 70 &&
        currentPos.accuracy.isFinite && currentPos.accuracy <= 50) {
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
    final step = _navigationSteps[_currentStepIndex];
    // Appelé DANS setState par la navigation : aucun setState imbriqué.
    _nextInstruction = _formatManeuver(step);
    _nextManeuverIcon = _getManeuverIcon(
      step['maneuver']['type'], step['maneuver']['modifier'] ?? '',
    );
  }

  // OSRM v1 returns maneuver.type/modifier, not maneuver.instruction.
  String _formatManeuver(dynamic step) {
    final type = step['maneuver']?['type']?.toString() ?? '';
    final modifier = step['maneuver']?['modifier']?.toString() ?? '';
    final road = step['name']?.toString() ?? '';
    String action;
    if (type == 'arrive') {
      action = 'Vous êtes arrivé';
    } else if (type == 'depart') {
      action = 'Démarrer';
    } else if (type == 'roundabout' || type == 'rotary') {
      action = 'Au rond-point, suivez votre sortie';
    } else if (type == 'turn' || type == 'new name' || type == 'fork') {
      if (modifier.contains('left')) {
        action = 'Tournez à gauche';
      } else if (modifier.contains('right')) {
        action = 'Tournez à droite';
      } else {
        action = 'Continuez';
      }
    } else {
      action = 'Continuez';
    }
    if (road.isNotEmpty && type != 'arrive') return '$action — $road';
    return action;
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
              onLongPress: (_, point) => _chooseDestination(point),
              onPositionChanged: (pos, hasGesture) {
                // Un geste déverrouille le recentrage temporairement.
                // Après 12 s sans nouveau geste, le suivi se réactive.
                if (hasGesture) _pauseFollowingForGesture();
              },
            ),
            children: [
              TileLayer(
                key: ValueKey('map_tiles_${_satelliteMode}_$_tileRefreshVersion'),
                urlTemplate: _satelliteMode ? _esriSatelliteUrl : _osmTileUrl,
                userAgentPackageName: 'com.mimo.spark',
                maxZoom: 19,
                errorTileCallback: (tile, error, stack) => _onMapTileError(),
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
                      width: 140, height: 140,
                      child: Center(
                        child: Transform.rotate(
                          // With MarkerLayer.rotate=false, marker follows the
                          // camera. Do not subtract camera.rotation again.
                          angle: VehicleMarkerHeading.rotationRadians(
                            _lastHeading,
                          ),
                          child: Image.asset(
                            'assets/images/Adobe Express - file.png',
                            width: 132,
                            height: 132,
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.high,
                            gaplessPlayback: true,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),

          // Attribution is visible, and live traffic is not falsely advertised.
          Positioned(
            bottom: 3,
            left: 6,
            right: 6,
            child: IgnorePointer(
              child: Text(
                _satelliteMode
                    ? 'Imagerie © Esri — sans trafic en temps réel'
                    : '© OpenStreetMap contributors — sans trafic en temps réel',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 9,
                  color: Colors.white,
                  shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                ),
              ),
            ),
          ),

          // BOUTON RETOUR VERS LE TABLEAU DE BORD
          Positioned(
            top: 0,
            left: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(top: 8, left: 12),
                child: Material(
                  color: Colors.black87,
                  shape: const CircleBorder(),
                  elevation: 6,
                  shadowColor: Colors.black54,
                  child: IconButton(
                    key: const Key('map_back_button'),
                    tooltip: 'Retour au tableau de bord',
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.maybePop(context),
                  ),
                ),
              ),
            ),
          ),

          if (_destination == null)
            Positioned(
              top: 0,
              left: 60,
              right: 60,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: IgnorePointer(
                    child: Center(
                      child: Text(
                        'Appui long sur la carte : choisir une destination',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // BOUTON BASCULE CARTE / SATELLITE
          Positioned(
            top: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  top: (_destination != null && _navigationSteps.isNotEmpty) ? 105 : 8,
                  right: 12,
                ),
                child: Material(
                  color: Colors.black87,
                  shape: const CircleBorder(),
                  elevation: 6,
                  shadowColor: Colors.black54,
                  child: IconButton(
                    tooltip: _satelliteMode ? 'Carte routière' : 'Vue satellite',
                    icon: Icon(
                      _satelliteMode ? Icons.map_outlined : Icons.satellite_alt_outlined,
                      color: Colors.white,
                    ),
                    onPressed: () => _refreshMapTiles(toggleSatellite: true),
                  ),
                ),
              ),
            ),
          ),

          // BANDEAU DE NAVIGATION
          if (_destination != null && _navigationSteps.isNotEmpty)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(top: 8, left: 68, right: 12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1B5E20),
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 15)],
                    ),
                    child: Row(
                      children: [
                        Icon(_nextManeuverIcon, color: Colors.white, size: 44),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _distanceToNextStep > 1000
                                  ? "${(_distanceToNextStep/1000).toStringAsFixed(1)} km"
                                  : "${_distanceToNextStep.toInt()} m",
                                style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900),
                              ),
                              Text(_nextInstruction, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500), maxLines: 2, overflow: TextOverflow.ellipsis),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
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
                tooltip: 'Recentrer et suivre ma voiture',
                onPressed: _resumeFollowing,
                child: const Icon(Icons.my_location, color: Colors.white),
              ),
            ),

          // BOUTON STOP NAVIGATION (uniquement quand une route est active)
          if (_destination != null)
            Positioned(
              bottom: 30, right: 16,
              child: FloatingActionButton(
                heroTag: 'stop', mini: true, backgroundColor: Colors.redAccent,
                onPressed: () {
                  _routeRequestGuard.invalidate();
                  setState(() {
                    _destination = null;
                    _routePoints = [];
                    _navigationSteps = [];
                    _currentStepIndex = 0;
                    _distanceToNextStep = 0;
                    _nextInstruction = 'Suivez la route';
                    _lastRecalculateTime = null;
                  });
                },
                child: const Icon(Icons.close, color: Colors.white),
              ),
            ),

          // Si plusieurs tuiles échouent, informer et proposer une action
          // volontaire ; ne jamais relancer des requêtes réseau en boucle.
          if (_tileRetryVisible)
            Positioned(
              bottom: 120,
              left: 16,
              right: 16,
              child: Material(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  child: Row(
                    children: [
                      const Icon(Icons.wifi_off, color: Colors.orangeAccent, size: 20),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Carte partiellement indisponible',
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                      TextButton(
                        key: const Key('map_retry_tiles_button'),
                        onPressed: _refreshMapTiles,
                        child: const Text('Réessayer'),
                      ),
                    ],
                  ),
                ),
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
