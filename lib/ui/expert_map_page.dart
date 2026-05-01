import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'dart:async';
import 'dart:math' as math;

class ExpertMapPage extends StatefulWidget {
  const ExpertMapPage({super.key});

  @override
  State<ExpertMapPage> createState() => _ExpertMapPageState();
}

class _ExpertMapPageState extends State<ExpertMapPage> {
  final MapController _mapController = MapController();
  final MapController _satController = MapController();

  Position? _currentPosition;
  double _lastHeading = 0;
  double _smoothedSpeed = 0;
  double _distanceKm = 0.0; // Distance placeholder or calculated
  
  // L'image de la Spark (vue 3/4 arrière) pointe vers le haut-gauche (-45°).
  // On ajoute 45° pour qu'elle pointe droit devant (Nord).
  static const double _imageRotationOffset = 45.0;

  int _viewMode = 0; // 0 = Split, 1 = Map Full, 2 = Sat Full
  double _zoomMap = 16.5;
  double _zoomSat = 14.0;

  StreamSubscription<Position>? _positionStream;
  Timer? _moveTimer;
  
  static const String _osmTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String _esriSatelliteUrl = 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';

  @override
  void initState() {
    super.initState();
    // Force landscape for the expert view to guarantee the beautiful layout
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeRight,
      DeviceOrientation.landscapeLeft,
    ]);
    _startLocationTracking();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _moveTimer?.cancel();
    // Revert to all orientations when leaving
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
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
      _moveSmooth(pos, _smoothedSpeed);
    } catch (_) {}

    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5),
    ).listen((Position pos) {
      if (!mounted) return;
      double speedKmh = pos.speed * 3.6;
      _smoothedSpeed = _smoothedSpeed + ((speedKmh - _smoothedSpeed) * 0.1);

      // On ne met à jour le cap (heading) que si la voiture roule (éviter qu'elle tourne sur elle-même au feu rouge)
      double currentHeading = _lastHeading;
      if (speedKmh > 3.0 && pos.heading >= 0) {
        currentHeading = pos.heading;
      }
      
      double smoothed = _smoothAngle(_lastHeading, currentHeading);

      setState(() {
        _currentPosition = pos;
        _lastHeading = smoothed;
        _distanceKm += (speedKmh / 3600) * (5 / 1000); // Rough simulation for demo
      });

      if (_smoothedSpeed > 2) {
        _moveSmooth(pos, _smoothedSpeed);
      }
    });
  }

  void _moveSmooth(Position pos, double speedKmh) {
    _moveTimer?.cancel();
    
    // Offset for Map (Waze style, car at bottom)
    double distanceMap = 0.00045 * math.pow(2, 17 - _zoomMap);
    double radMap = _lastHeading * (math.pi / 180);
    LatLng targetMap = LatLng(pos.latitude + distanceMap * math.cos(radMap), pos.longitude + distanceMap * math.sin(radMap));
    
    // Sat map is centered directly on the car
    LatLng targetSat = LatLng(pos.latitude, pos.longitude);

    _moveTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (!mounted) { timer.cancel(); return; }

      // Map Update
      final currentMap = _mapController.camera.center;
      double latMap = currentMap.latitude + (targetMap.latitude - currentMap.latitude) * 0.1;
      double lngMap = currentMap.longitude + (targetMap.longitude - currentMap.longitude) * 0.1;
      double rotMap = -_lastHeading % 360;
      if (rotMap > 180) rotMap -= 360;
      if (rotMap < -180) rotMap += 360;
      _mapController.moveAndRotate(LatLng(latMap, lngMap), _zoomMap, rotMap);

      // Sat Update (No rotation)
      final currentSat = _satController.camera.center;
      double latSat = currentSat.latitude + (targetSat.latitude - currentSat.latitude) * 0.1;
      double lngSat = currentSat.longitude + (targetSat.longitude - currentSat.longitude) * 0.1;
      _satController.move(LatLng(latSat, lngSat), _zoomSat);

      if ((latMap - targetMap.latitude).abs() < 0.000001 && (lngMap - targetMap.longitude).abs() < 0.000001) {
        timer.cancel();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0C10),
      body: Row(
        children: [
          // 1. LEFT SIDEBAR
          Container(
            width: 260,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF0A0C18), Colors.black],
                begin: Alignment.topCenter, end: Alignment.bottomCenter,
              ),
              border: Border(right: BorderSide(color: Colors.white10)),
            ),
            child: Column(
              children: [
                const SizedBox(height: 10),
                const Text("MIMO SPARK", style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: 2)),
                const Text("Votre voiture. Vos données.", style: TextStyle(color: Colors.cyanAccent, fontSize: 10)),
                const SizedBox(height: 16),
                
                // Photo of Spark
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.asset('assets/images/spark alpha.jpeg', height: 120, width: double.infinity, fit: BoxFit.cover),
                  ),
                ),
                
                const SizedBox(height: 16),
                
                // Grid Buttons
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: GridView.count(
                      crossAxisCount: 2,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 1.2,
                      children: [
                        _buildMenuButton("Tableau de\nbord", Icons.dashboard, false, () => Navigator.pop(context)),
                        _buildMenuButton("Carte & GPS", Icons.location_on, true, () {}),
                        _buildMenuButton("Diagnostic\nOBD", Icons.engineering, false, () {
                           Navigator.pop(context); // User can launch from dashboard
                           ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Veuillez lancer le diag depuis le Tableau de bord')));
                        }),
                        _buildMenuButton("Mode Miroir\n(HUD)", Icons.flip_to_front, false, () {
                           ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Le Mode HUD est activable dans le Tableau de Bord')));
                        }),
                      ],
                    ),
                  ),
                ),
                
                // Start Button
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: ElevatedButton(
                    onPressed: () {},
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueAccent[700],
                      minimumSize: const Size(double.infinity, 50),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text("Démarrer", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                ),
                
                // Status
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.circle, color: Colors.greenAccent, size: 10),
                      SizedBox(width: 6),
                      Text("OBD Connecté", style: TextStyle(color: Colors.greenAccent, fontSize: 12)),
                    ],
                  ),
                )
              ],
            ),
          ),

          // 2. RIGHT MAPS AREA
          Expanded(
            child: Column(
              children: [
                // The Maps Split View
                Expanded(
                  child: Row(
                    children: [
                      // Map 1 (OSM - Waze style)
                      if (_viewMode == 0 || _viewMode == 1)
                        Expanded(
                          child: Stack(
                            children: [
                              _buildMapLayer(
                                controller: _mapController,
                                url: _osmTileUrl,
                                zoom: _zoomMap,
                                isMap1: true,
                                onZoomChange: (z) => _zoomMap = z,
                              ),
                              Positioned(
                                top: 10, right: 10,
                                child: IconButton(
                                  icon: Icon(_viewMode == 1 ? Icons.close_fullscreen : Icons.fullscreen, color: Colors.black, size: 30),
                                  onPressed: () => setState(() => _viewMode = _viewMode == 1 ? 0 : 1),
                                  style: IconButton.styleFrom(backgroundColor: Colors.white70),
                                ),
                              ),
                            ],
                          ),
                        ),
                        
                      // Divider
                      if (_viewMode == 0)
                        Container(width: 4, color: Colors.black),
                        
                      // Map 2 (Satellite)
                      if (_viewMode == 0 || _viewMode == 2)
                        Expanded(
                          child: Stack(
                            children: [
                              _buildMapLayer(
                                controller: _satController,
                                url: _esriSatelliteUrl,
                                zoom: _zoomSat,
                                isMap1: false,
                                onZoomChange: (z) => _zoomSat = z,
                              ),
                              Positioned(
                                top: 10, left: 10,
                                child: IconButton(
                                  icon: Icon(_viewMode == 2 ? Icons.close_fullscreen : Icons.fullscreen, color: Colors.white, size: 30),
                                  onPressed: () => setState(() => _viewMode = _viewMode == 2 ? 0 : 2),
                                  style: IconButton.styleFrom(backgroundColor: Colors.black54),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                
                // Bottom Info Bar
                Container(
                  height: 80,
                  decoration: const BoxDecoration(
                    color: Color(0xFF151820),
                    border: Border(top: BorderSide(color: Colors.white10)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildBottomStat("${_smoothedSpeed.toInt()} km/h", "Vitesse"),
                      Container(width: 1, color: Colors.white10, height: 40),
                      _buildBottomStat("${_distanceKm.toStringAsFixed(1)} km", "Distance"),
                      Container(width: 1, color: Colors.white10, height: 40),
                      _buildBottomStat(DateFormat('HH:mm').format(DateTime.now()), "Heure"),
                    ],
                  ),
                )
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildMapLayer({
    required MapController controller,
    required String url,
    required double zoom,
    required bool isMap1,
    required Function(double) onZoomChange,
  }) {
    LatLng centerPos = _currentPosition != null ? LatLng(_currentPosition!.latitude, _currentPosition!.longitude) : const LatLng(36.7538, 3.0588);
    
    return FlutterMap(
      mapController: controller,
      options: MapOptions(
        initialCenter: centerPos,
        initialZoom: zoom,
        maxZoom: 19,
        minZoom: 3,
        onPositionChanged: (pos, hasGesture) {
          if (pos.zoom != null && pos.zoom != zoom) {
            onZoomChange(pos.zoom!);
            setState(() {});
          }
        },
      ),
      children: [
        TileLayer(urlTemplate: url, maxZoom: 19, keepBuffer: 5), // Supprimé tileDisplay.fadeIn pour éviter le fond blanc
        if (_currentPosition != null)
          MarkerLayer(
            markers: [
              Marker(
                point: centerPos,
                width: 150, height: 150,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Transform.rotate(
                      angle: isMap1 ? 0 : _lastHeading * (math.pi / 180), // Map1 rotates the whole map, so car stays pointing up
                      child: Container(
                        width: (40 + (zoom - 12) * 20).clamp(20, 150),
                        height: (40 + (zoom - 12) * 20).clamp(20, 150),
                        decoration: BoxDecoration(boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 10, spreadRadius: 2)]),
                      ),
                    ),
                    Transform.rotate(
                      angle: (isMap1 ? _imageRotationOffset : (_lastHeading + _imageRotationOffset)) * (math.pi / 180),
                      child: Image.asset(
                        'assets/images/spark alpha.jpeg',
                        width: (80 + (zoom - 12) * 35).clamp(40, 250),
                        height: (80 + (zoom - 12) * 35).clamp(40, 250),
                        fit: BoxFit.contain, filterQuality: FilterQuality.high,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildMenuButton(String title, IconData icon, bool isSelected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: isSelected ? Colors.blueAccent.withOpacity(0.2) : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: isSelected ? Colors.blueAccent : Colors.transparent, width: 2),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: isSelected ? Colors.blueAccent : Colors.white70, size: 28),
            const SizedBox(height: 8),
            Text(title, style: TextStyle(color: isSelected ? Colors.white : Colors.white70, fontSize: 11, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomStat(String value, String label) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
      ],
    );
  }
}
