import '../core/api_client.dart';

class Waypoint {
  final double lat;
  final double lng;

  const Waypoint({required this.lat, required this.lng});

  Map<String, dynamic> toJson() => {'lat': lat, 'lng': lng};

  factory Waypoint.fromJson(Map<String, dynamic> json) => Waypoint(
        lat: (json['lat'] as num).toDouble(),
        lng: (json['lng'] as num).toDouble(),
      );
}

enum RouteStatus { draft, active, completed, aborted }

class SpediRoute {
  final String id;
  final String deviceId;
  final String name;
  final List<Waypoint> waypoints;
  final RouteStatus status;

  const SpediRoute({
    required this.id,
    required this.deviceId,
    required this.name,
    required this.waypoints,
    required this.status,
  });

  factory SpediRoute.fromJson(Map<String, dynamic> json) => SpediRoute(
        id: json['id'] as String,
        deviceId: json['device_id'] as String,
        name: json['name'] as String,
        waypoints: (json['waypoints'] as List)
            .map((w) => Waypoint.fromJson(w as Map<String, dynamic>))
            .toList(),
        status: RouteStatus.values.firstWhere(
          (s) => s.name == json['status'],
          orElse: () => RouteStatus.draft,
        ),
      );
}

class RouteService {
  final _client = ApiClient.instance;

  /// Buat draft route baru. Minimal 2 waypoint diperlukan.
  /// 
  /// Throws [ApiException] 400 jika waypoint < 2.
  Future<SpediRoute> createRoute({
    required String deviceId,
    required String name,
    required List<Waypoint> waypoints,
  }) async {
    assert(waypoints.length >= 2, 'Minimal 2 waypoints diperlukan');

    final data = await _client.post(
      '/routes',
      body: {
        'device_id': deviceId,
        'name': name,
        'waypoints': waypoints.map((w) => w.toJson()).toList(),
      },
    );
    return SpediRoute.fromJson(data);
  }

  /// Dispatch route ke device via MQTT. Status berubah dari draft → active.
  Future<SpediRoute> startRoute(String routeId) async {
    final data = await _client.post('/routes/$routeId/start');
    return SpediRoute.fromJson(data);
  }

  /// Abort route yang sedang berjalan. Device kembali ke idle.
  Future<SpediRoute> stopRoute(String routeId) async {
    final data = await _client.post('/routes/$routeId/stop');
    return SpediRoute.fromJson(data);
  }

  /// Hapus draft route. Hanya bisa jika status masih "draft".
  /// 
  /// Throws [ApiException] 409 jika route sudah active/completed.
  Future<void> deleteRoute(String routeId) async {
    await _client.delete('/routes/$routeId');
  }
}