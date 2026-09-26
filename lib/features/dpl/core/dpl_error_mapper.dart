import 'package:dio/dio.dart';

import 'dpl_api_response.dart';

/// Centralised conversion of [DioException] / generic errors into
/// a user-friendly [DplApiResponse.error].
class DplErrorMapper {
  const DplErrorMapper._();

  static DplApiResponse<T> fromDio<T>(
    DioException error, {
    required String fallback,
  }) {
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout) {
      return DplApiResponse.error(
        'Request timed out. Please check your connection and try again.',
        code: 'TIMEOUT',
      );
    }

    if (error.type == DioExceptionType.connectionError) {
      return DplApiResponse.error(
        'Network error, please check connection.',
        code: 'NETWORK',
      );
    }

    final statusCode = error.response?.statusCode;
    final data = error.response?.data;

    // A 500 is shown to the operator as "Something went wrong" on purpose —
    // a stack trace helps nobody on a shop floor. But it must not be
    // swallowed on the way past, or a server fault is invisible to everyone
    // including whoever has to fix it. In a debug build the real body goes to
    // the console, where `adb logcat -s flutter` can read it off a handheld.
    assert(() {
      if (statusCode != null && statusCode >= 500) {
        // ignore: avoid_print
        print(
          'DPL_API_5XX status=$statusCode '
          'path=${error.requestOptions.method} ${error.requestOptions.path} '
          'body=$data',
        );
      }
      return true;
    }());

    String? apiMessage;
    String? apiCode;

    if (data is Map) {
      final map = Map<String, dynamic>.from(data);
      final rawMessage = map['error'] ?? map['message'];
      if (rawMessage is String && rawMessage.trim().isNotEmpty) {
        apiMessage = rawMessage.trim();
      }
      final rawCode = map['code'];
      if (rawCode is String && rawCode.trim().isNotEmpty) {
        apiCode = rawCode.trim();
      }
    } else if (data is String && data.trim().isNotEmpty) {
      apiMessage = data.trim();
    }

    String message;
    switch (statusCode) {
      case 400:
        message = apiMessage ?? 'Please check your input and try again.';
        break;
      case 401:
        // Multi-tenant: when an admin reassigns a user's org server-side
        // after they logged in, the next request comes back as 401 with
        // code ORG_MISMATCH. Treat it like a hard session expiry so the
        // Dio interceptor logs the user out and the message is honest
        // about why.
        if (apiCode == 'ORG_MISMATCH') {
          message = apiMessage ??
              'Your organization assignment changed. Please log in again.';
        } else {
          message = apiMessage ?? 'Session expired. Please log in again.';
          apiCode ??= 'UNAUTHORIZED';
        }
        break;
      case 403:
        message = apiMessage ??
            "You don't have permission for this action.";
        apiCode ??= 'FORBIDDEN';
        break;
      case 404:
        message = apiMessage ?? 'Record not found.';
        break;
      case 409:
        message = apiMessage ?? 'Conflict — record already exists.';
        apiCode ??= 'CONFLICT';
        break;
      case 422:
        message = apiMessage ?? 'Validation failed.';
        break;
      default:
        if (statusCode != null && statusCode >= 500) {
          // Misconfigured-user case: a user record with no organization
          // can't be served by any of the auto-filtered queries. Surface
          // a concrete next step instead of the generic 500 string.
          if (apiCode == 'NO_ORGANIZATION') {
            message = apiMessage ??
                'Your account has no organization assigned. Please contact your administrator.';
          } else {
            message = 'Something went wrong, please try again.';
          }
        } else {
          message = apiMessage ?? fallback;
        }
    }

    return DplApiResponse.error(
      message,
      code: apiCode,
      statusCode: statusCode,
    );
  }

  static DplApiResponse<T> fromObject<T>(
    Object error, {
    required String fallback,
  }) {
    if (error is DioException) {
      return fromDio<T>(error, fallback: fallback);
    }
    return DplApiResponse.error(error.toString().isEmpty
        ? fallback
        : error.toString());
  }
}
