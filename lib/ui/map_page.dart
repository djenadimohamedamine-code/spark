import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:math' as math;

class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final MapController _mapController = MapController();
  Position? _currentPosition;
  bool _isFollowing = true;
  bool _satelliteMode = true;
  StreamSubscription<Position>? _positionStream;
  Timer? _moveTimer; // Pour le glissement fluide "Tesla-style"
  double _lastHeading = 0;
  bool _rotateMap = false; // Mode Direction Lock (Tesla style)

  // Lissage spécial pour les angles (Transition 359-0)
  double _smoothAngle(double current, double target) {
    double diff = target - current;
    while (diff > 180) diff -= 360;
    while (diff < -180) diff += 360;
    // Lissage 8% pour plus d'inertie (Pro Style)
    return current + (diff * 0.08); 
  }

  // Calcul de l'offset dynamique (Garde la voiture en bas de l'écran peu importe le sens)
  LatLng _getOffsetPosition(Position pos, double heading) {
    const double distance = 0.00045; // Ajuste selon le zoom
    double rad = (heading) * (math.pi / 180);

    double latOffset = distance * math.cos(rad);
    double lngOffset = distance * math.sin(rad);

    return LatLng(
      pos.latitude + latOffset, // On décale la CAMÉRA vers l'avant (donc voiture en bas)
      pos.longitude + lngOffset,
    );
  }

  // Position par défaut : Alger
  static const LatLng _defaultPosition = LatLng(36.7538, 3.0588);

  // Tuiles OpenStreetMap (plan, gratuit)
  static const String _osmTileUrl =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  // Tuiles ESRI Satellite (vue satellite, gratuit, pas d'API key)
  static const String _esriSatelliteUrl =
      'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';

  @override
  void initState() {
    super.initState();
    // Mode nuit automatique
    final hour = DateTime.now().hour;
    if (hour < 6 || hour > 18) _satelliteMode = true; 
    _startLocationTracking();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _moveTimer?.cancel();
    super.dispose();
  }

  Future<void> _startLocationTracking() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Activez la localisation GPS dans les paramètres'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    if (permission == LocationPermission.deniedForever) return;

    // Position initiale rapide
    try {
      Position pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      if (mounted) {
        setState(() {
          _currentPosition = pos;
          // Initial heading smooth
          _lastHeading = pos.heading >= 0 ? pos.heading : 0;
        });
        _moveSmooth(pos, 0);
      }
    } catch (_) {}

    // Suivi continu — seulement si déplacé de 5m (économise la batterie)
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen((Position pos) {
      if (!mounted) return;
      
      // 1. Filtre de précision (Évite les sauts GPS brusques)
      if (pos.accuracy > 25) return;

      // 2. Gestion intelligente du Heading (Google Maps Style)
      double speedKmh = pos.speed * 3.6;
      
      // Standstill Lock (Fige la flèche à l'arrêt complet)
      if (speedKmh < 2) return;

      double currentHeading = pos.heading;
      if (currentHeading < 0) currentHeading = _lastHeading;

      // 3. Lissage circulaire (Inertie 8% Pro)
      double diff = currentHeading - _lastHeading;
      if (diff > 180) diff -= 360;
      if (diff < -180) diff += 360;
      
      // Haptic Feedback sur virage serré
      if (diff.abs() > 25) {
        HapticFeedback.lightImpact();
      }

      double smoothed = _smoothAngle(_lastHeading, currentHeading);
      
      setState(() {
        _currentPosition = pos;
        _lastHeading = smoothed;
      });
      
      if (_isFollowing) _moveSmooth(pos, speedKmh);
    });
  }

  void _moveSmooth(Position pos, double speedKmh) {
    _moveTimer?.cancel(); // On annule l'ancien glissement
    
    final target = _getOffsetPosition(pos, _lastHeading);
    final double targetZoom = (speedKmh > 80) ? 15.5 : (speedKmh > 40) ? 16.5 : 17.5;
    
    // Timer 60 FPS (16ms) pour un rendu Waze/Tesla parfait
    _moveTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (!mounted) { timer.cancel(); return; }

      final current = _mapController.camera.center;
      // Interpolation 10% par tick (Smooth total)
      double lat = current.latitude + (target.latitude - current.latitude) * 0.1;
      double lng = current.longitude + (target.longitude - current.longitude) * 0.1;

      _mapController.moveAndRotate(LatLng(lat, lng), targetZoom, _rotateMap ? -_lastHeading : 0);

      // Si on est assez proche de la cible, on arrête le timer
      if ((lat - target.latitude).abs() < 0.000001 && (lng - target.longitude).abs() < 0.000001) {
        timer.cancel();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final LatLng centerPos = _currentPosition != null
        ? LatLng(_currentPosition!.latitude, _currentPosition!.longitude)
        : _defaultPosition;

    final double speedKmh = (_currentPosition?.speed ?? 0) * 3.6;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Navigation GPS',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900),
            ),
            if (_currentPosition != null)
              Text(
                '${speedKmh.toInt()} km/h  •  Cap: ${_lastHeading.toInt()}°  •  ±${_currentPosition!.accuracy.toInt()} m',
                style: const TextStyle(color: Colors.greenAccent, fontSize: 10),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              _rotateMap ? Icons.explore : Icons.explore_off,
              color: _rotateMap ? Colors.greenAccent : Colors.white24,
            ),
            tooltip: 'Direction Lock (Tesla Mode)',
            onPressed: () {
               setState(() => _rotateMap = !_rotateMap);
               HapticFeedback.mediumImpact();
            },
          ),
          IconButton(
            icon: Icon(
              _satelliteMode ? Icons.map_outlined : Icons.satellite_alt,
              color: Colors.cyanAccent,
            ),
            tooltip: _satelliteMode ? 'Mode Plan (OSM)' : 'Mode Satellite (ESRI)',
            onPressed: () => setState(() => _satelliteMode = !_satelliteMode),
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: centerPos,
              initialZoom: 17.0,
              maxZoom: 19,
              minZoom: 3,
              onPositionChanged: (pos, hasGesture) {
                if (hasGesture && _isFollowing) {
                  setState(() => _isFollowing = false);
                }
              },
            ),
            children: [
              // Couche principale : Satellite ESRI ou OSM plan
              TileLayer(
                urlTemplate: _satelliteMode ? _esriSatelliteUrl : _osmTileUrl,
                userAgentPackageName: 'com.mimo.spark',
                maxZoom: 19,
                keepBuffer: 20, // Buffer pro
                tileDisplay: const TileDisplay.fadeIn(),
              ),

              // Si satellite : couche de noms de rues (hybride)
              if (_satelliteMode)
                TileLayer(
                  urlTemplate:
                      'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
                  userAgentPackageName: 'com.mimo.spark',
                  maxZoom: 19,
                  keepBuffer: 20, // Buffer pro pour éviter les zones blanches
                  tileDisplay: const TileDisplay.fadeIn(),
                ),

              // Marqueur position actuelle (Spark avec rotation dynamique)
              if (_currentPosition != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: centerPos,
                      width: 70, // Taille ajustée
                      height: 70,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // 2. Ombre dynamique RÉALISTE (Dégradé radial)
                          Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  Colors.black.withOpacity(0.5),
                                  Colors.transparent,
                                ],
                              ),
                            ),
                          ),
                          Transform.rotate(
                            // Lissage + Offset +90
                            angle: (_lastHeading + 90) * (3.14159 / 180),
                            child: Image.asset(
                              'assets/images/spark_marker.png',
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.high,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
            ],
          ),

          // Vitesse GPS en bas à gauche
          Positioned(
            bottom: 24,
            left: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${speedKmh.toInt()} km/h',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 28, fontWeight: FontWeight.w900),
                  ),
                  const Text('GPS Satellite', style: TextStyle(color: Colors.white38, fontSize: 10)),
                ],
              ),
            ),
          ),

          // Bouton Recentrer / Suivre
          Positioned(
            bottom: 24,
            right: 16,
            child: FloatingActionButton(
              heroTag: 'fab_gps',
              backgroundColor: _isFollowing ? Colors.cyanAccent : Colors.black87,
              onPressed: () {
                setState(() => _isFollowing = true);
                if (_currentPosition != null) _moveSmooth(_currentPosition!, speedKmh);
              },
              child: Icon(
                _isFollowing ? Icons.gps_fixed : Icons.gps_not_fixed,
                color: _isFollowing ? Colors.black : Colors.cyanAccent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
