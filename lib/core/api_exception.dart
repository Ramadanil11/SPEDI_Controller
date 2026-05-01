class ApiException implements Exception {
  final int statusCode;
  final String message;

  const ApiException({required this.statusCode, required this.message});

  factory ApiException.fromStatusCode(int code, String body) {
    switch (code) {
      case 400:
        return ApiException(statusCode: code, message: 'Bad request: $body');
      case 401:
        return ApiException(statusCode: code, message: 'Backend belum terhubung (token tidak dikenali).');
      case 403:
        return ApiException(statusCode: code, message: 'Forbidden. Access denied.');
      case 404:
        return ApiException(statusCode: code, message: 'Not found.');
      case 409:
        return ApiException(statusCode: code, message: 'Conflict: $body');
      case 500:
        return ApiException(statusCode: code, message: 'Server error. Please try again later.');
      default:
        return ApiException(statusCode: code, message: 'Unexpected error ($code): $body');
    }
  }

  @override
  String toString() => 'ApiException[$statusCode]: $message';
}