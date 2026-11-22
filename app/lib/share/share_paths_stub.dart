/// No share sheet on the web: nothing to filter.
Future<bool Function(String path)> sharedPathFilter() async => (_) => true;
