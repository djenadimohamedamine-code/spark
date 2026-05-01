import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:syncfusion_flutter_gauges/gauges.dart';

class StandaloneClockPage extends StatelessWidget {
  const StandaloneClockPage({super.key});

  Widget _buildGlassCard({required Widget child, required double height}) {
    return Container(
      height: height,
      margin: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: const Color(0xFF121212).withOpacity(0.7),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 15, offset: const Offset(0, 5))
        ],
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Background
          Container(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.center,
                radius: 1.5,
                colors: [Color(0xFF0A0C18), Colors.black],
              ),
            ),
          ),
          SafeArea(
            child: StreamBuilder(
              stream: Stream.periodic(const Duration(seconds: 1)),
              builder: (context, snapshot) {
                final timeStr = DateFormat('HH:mm').format(DateTime.now());
                final now = DateTime.now();
                double hourValue = (now.hour % 12) + (now.minute / 60.0);
                double minuteValue = now.minute / 5.0;
                double secondValue = now.second / 5.0;

                return Center(
                  child: _buildGlassCard(
                    height: 350,
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      child: FittedBox(
                        fit: BoxFit.contain,
                        child: SizedBox(
                          width: 300,
                          height: 300,
                          child: SfRadialGauge(
                            axes: <RadialAxis>[
                              RadialAxis(
                                minimum: 0, maximum: 12,
                                startAngle: 270, endAngle: 270,
                                showLabels: true,
                                showTicks: true,
                                interval: 1,
                                minorTicksPerInterval: 4,
                                axisLabelStyle: const GaugeTextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.bold),
                                majorTickStyle: const MajorTickStyle(length: 14, thickness: 3, color: Colors.cyanAccent),
                                minorTickStyle: const MinorTickStyle(length: 7, thickness: 1.5, color: Colors.white30),
                                axisLineStyle: const AxisLineStyle(thickness: 2, color: Colors.white10),
                                pointers: <GaugePointer>[
                                  NeedlePointer(
                                    value: hourValue,
                                    needleColor: Colors.cyanAccent,
                                    needleLength: 0.55,
                                    needleStartWidth: 5,
                                    needleEndWidth: 12,
                                    knobStyle: const KnobStyle(color: Colors.white, knobRadius: 0.07),
                                    enableAnimation: true, animationDuration: 300
                                  ),
                                  NeedlePointer(
                                    value: minuteValue,
                                    needleColor: Colors.blueAccent,
                                    needleLength: 0.75,
                                    needleStartWidth: 3,
                                    needleEndWidth: 9,
                                    knobStyle: const KnobStyle(color: Colors.white, knobRadius: 0.07),
                                    enableAnimation: true, animationDuration: 300
                                  ),
                                  NeedlePointer(
                                    value: secondValue,
                                    needleColor: Colors.redAccent,
                                    needleLength: 0.9,
                                    needleStartWidth: 1.5,
                                    needleEndWidth: 1.5,
                                    knobStyle: const KnobStyle(color: Colors.redAccent, knobRadius: 0.05),
                                    enableAnimation: true, animationDuration: 300
                                  ),
                                ],
                                annotations: <GaugeAnnotation>[
                                  GaugeAnnotation(
                                    widget: Text(timeStr, style: const TextStyle(color: Colors.cyanAccent, fontSize: 28, fontWeight: FontWeight.bold, letterSpacing: 2)),
                                    angle: 90,
                                    positionFactor: 0.5,
                                  )
                                ]
                              )
                            ]
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Positioned(
            top: 20,
            left: 20,
            child: SafeArea(
              child: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.cyanAccent, size: 30),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
