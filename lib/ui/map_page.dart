import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:async';

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
    _startLocationTracking();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
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
        setState(() => _currentPosition = pos);
        _moveTo(pos);
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
      setState(() => _currentPosition = pos);
      if (_isFollowing) _moveTo(pos);
    });
  }

  void _moveTo(Position pos) {
    _mapController.move(
      LatLng(pos.latitude, pos.longitude),
      17.5,
    );
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
                '${speedKmh.toInt()} km/h  •  Alt: ${_currentPosition!.altitude.toInt()} m  •  ±${_currentPosition!.accuracy.toInt()} m',
                style: const TextStyle(color: Colors.greenAccent, fontSize: 10),
              ),
          ],
        ),
        actions: [
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
                // Si l'utilisateur bouge manuellement la carte, désactiver le suivi
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
              ),

              // Si satellite : couche de noms de rues (hybride)
              if (_satelliteMode)
                TileLayer(
                  urlTemplate:
                      'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
                  userAgentPackageName: 'com.mimo.spark',
                  maxZoom: 19,
                ),

              // Marqueur position actuelle
              if (_currentPosition != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: centerPos,
                      width: 56,
                      height: 56,
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.cyanAccent, width: 3),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.cyanAccent.withOpacity(0.5),
                              blurRadius: 10,
                              spreadRadius: 2,
                            )
                          ],
                          image: const DecorationImage(
                            image: AssetImage('assets/images/spark2.png'),
                            fit: BoxFit.cover,
                          ),
                        ),
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
                if (_currentPosition != null) _moveTo(_currentPosition!);
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
