abstract final class AppConfig {
  static const String apiBaseUrl = String.fromEnvironment(
    'FOTOSEARCH_API_BASE_URL',
    defaultValue: 'https://fotosearch-theta.vercel.app/api',
  );
  static const requestTimeoutSeconds = 30;
  static const healthTimeoutSeconds = 8;
  static const searchLimit = 30;
}
