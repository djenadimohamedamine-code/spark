import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
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
  double _lastHeading = 0;
  double _smoothedSpeed = 0;
  double _distanceKm = 0.0;

  bool _satelliteMode = false;
  bool _isFollowing = true;

  // Offset de rotation de l'image pour que le capot pointe vers le haut (Nord)
  static const double _carRotationOffset = -45.0;

  StreamSubscription<Position>? _positionStream;

  static const String _googleTrafficUrl    = 'https://mt0.google.com/vt/lyrs=m,traffic&hl=fr&x={x}&y={y}&z={z}';
  static const String _googleSatelliteUrl  = 'https://mt0.google.com/vt/lyrs=y&hl=fr&x={x}&y={y}&z={z}'; // Satellite Google (même proj. que Traffic)

  @override
  void initState() {
    super.initState();
    // Default to Google Maps Traffic.
    _startLocationTracking();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
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

  // Suit la position GPS instantanément (comme Google Maps)
  void _followPosition(Position pos, double speedKmh) {
    if (!mounted) return;
    double targetZoom = (speedKmh > 80) ? 16.0 : (speedKmh > 40) ? 17.0 : 18.2;
    // Décalage vers le haut pour voir la route devant (style Waze)
    final offsetLat = pos.latitude + 0.0003;
    _mapController.move(LatLng(offsetLat, pos.longitude), targetZoom);
  }

  @override
  Widget build(BuildContext context) {
    String etaText = "--:--";
    if (_smoothedSpeed > 10 && _distanceKm > 0) {
      double hoursRemaining = _distanceKm / _smoothedSpeed;
      DateTime eta = DateTime.now().add(Duration(minutes: (hoursRemaining * 60).toInt()));
      etaText = DateFormat('HH:mm').format(eta);
    }

    final centerPos = _currentPosition != null
        ? LatLng(_currentPosition!.latitude, _currentPosition!.longitude)
        : const LatLng(36.8065, 10.1815);

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: centerPos,
              initialZoom: 18.2,
              onPositionChanged: (pos, hasGesture) {
                if (hasGesture && _isFollowing) setState(() => _isFollowing = false);
              },
            ),
            children: [
              TileLayer(
                urlTemplate: _satelliteMode ? _googleSatelliteUrl : _googleTrafficUrl,
                userAgentPackageName: 'com.mimo.spark',
                maxZoom: 20,
                keepBuffer: 4,
              ),
              // Pas de layer labels séparé (Google Satellite 'y' inclut déjà les noms de rues)
              if (_currentPosition != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: centerPos,
                      width: 120, height: 120,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // Halo GPS bleu (plus discret, style Google Maps)
                          Container(
                            width: 60, height: 60,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.blue.withOpacity(0.15),
                              border: Border.all(color: Colors.blue.withOpacity(0.2), width: 1),
                            ),
                          ),
                          // Voiture — taille proportionnelle au zoom (style Waze)
                          Transform.rotate(
                            angle: (_lastHeading + _carRotationOffset) * (math.pi / 180),
                            child: LayoutBuilder(builder: (context, constraints) {
                              final mapZoom = _mapController.camera.zoom;
                              final carSize = (mapZoom * 2.8).clamp(28.0, 55.0);
                              return Image.asset(
                                'assets/images/Adobe Express - file.png',
                                width: carSize,
                                height: carSize,
                                fit: BoxFit.contain,
                                filterQuality: FilterQuality.high,
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

          // Bouton Satellite en haut à droite
          Positioned(
            top: 40, right: 16,
            child: FloatingActionButton(
              heroTag: 'sat',
              mini: true,
              backgroundColor: Colors.black87,
              onPressed: () => setState(() => _satelliteMode = !_satelliteMode),
              child: Icon(_satelliteMode ? Icons.map : Icons.satellite_alt, color: Colors.white),
            ),
          ),
          
          // Bouton Recentrer
          Positioned(
            bottom: 100, right: 16,
            child: FloatingActionButton(
              heroTag: 'center',
              backgroundColor: _isFollowing ? Colors.cyanAccent : Colors.black87,
              onPressed: () {
                setState(() => _isFollowing = true);
                if (_currentPosition != null) _followPosition(_currentPosition!, _smoothedSpeed);
              },
              child: Icon(_isFollowing ? Icons.gps_fixed : Icons.gps_not_fixed, color: _isFollowing ? Colors.black : Colors.cyanAccent),
            ),
          ),

          // Barre de bas "Distance & ETA"
          Positioned(
            bottom: 24, left: 20, right: 20,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(color: Colors.cyanAccent.withOpacity(0.5), width: 2),
                  boxShadow: [BoxShadow(color: Colors.cyanAccent.withOpacity(0.2), blurRadius: 10)],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.route, color: Colors.cyanAccent, size: 24),
                    const SizedBox(width: 8),
                    Text('${_distanceKm.toStringAsFixed(1)} KM', style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 24),
                    const Icon(Icons.flag, color: Colors.greenAccent, size: 24),
                    const SizedBox(width: 8),
                    Text(etaText, style: const TextStyle(color: Colors.greenAccent, fontSize: 20, fontWeight: FontWeight.bold)),
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
