/// Generic wrapper around the DPL backend's response envelope.
///
/// The backend returns:
///   { "success": true,  "data": { ... } }            on success
///   { "success": false, "error": "msg", "code": "?" } on failure
///
/// We mirror that here, but we also use this type as the *all-purpose*
/// transport between the API service and the UI layer: a network failure
/// is converted into `DplApiResponse.error(message)` so the UI never sees
/// a raw exception.
class DplApiResponse<T> {
  final bool success;
  final T? data;
  final String? error;
  final String? code;
  final int? statusCode;

  /// The server's translation of [error] into the operator's language
  /// (Marathi / Hindi), when the app asked for one and the code has one.
  /// [error] always stays English; show both on the floor.
  final String? errorLocal;

  const DplApiResponse._({
    required this.success,
    this.data,
    this.error,
    this.code,
    this.statusCode,
    this.errorLocal,
  });

  factory DplApiResponse.ok(T? data) =>
      DplApiResponse._(success: true, data: data);

  factory DplApiResponse.error(
    String message, {
    String? code,
    int? statusCode,
    String? errorLocal,
  }) =>
      DplApiResponse._(
        success: false,
        error: message,
        code: code,
        statusCode: statusCode,
        errorLocal: errorLocal,
      );

  /// The message to show an operator: the local-language line first, then
  /// the English with its serial or pallet number.
  String get floorMessage =>
      errorLocal == null ? (error ?? '') : '$errorLocal\n${error ?? ''}';

  bool get isOk => success;
  bool get isError => !success;

  /// Returns [data] when present, otherwise the caller-provided fallback.
  T dataOr(T fallback) => data ?? fallback;
}

/// A paginated response shape used by endpoints like `GET /parts`.
class DplPagedResult<T> {
  final List<T> items;
  final int page;
  final int limit;
  final int total;

  const DplPagedResult({
    required this.items,
    required this.page,
    required this.limit,
    required this.total,
  });

  bool get hasMore => page * limit < total;

  factory DplPagedResult.empty() => const DplPagedResult(
        items: [],
        page: 1,
        limit: 20,
        total: 0,
      );

  static DplPagedResult<T> fromJson<T>(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) fromMap, {
    String itemsKey = 'items',
  }) {
    int parseInt(dynamic v, int fallback) {
      if (v is int) return v;
      if (v is double) return v.toInt();
      return int.tryParse(v?.toString() ?? '') ?? fallback;
    }

    final raw = json[itemsKey];
    final list = raw is List
        ? raw
            .whereType<Map>()
            .map((e) => fromMap(Map<String, dynamic>.from(e)))
            .toList()
        : <T>[];

    return DplPagedResult<T>(
      items: list,
      page: parseInt(json['page'], 1),
      limit: parseInt(json['limit'], list.length),
      total: parseInt(json['total'], list.length),
    );
  }
}
