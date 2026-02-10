/// Main-thread handler for in-memory storage.
///
/// This handler does not require any worker-side connectors.
library;

import '../shared/consts.dart';
import 'storage_main_handler.dart';
import 'main_handler.dart';

class InMemoryStorageMainHandler extends StorageMainHandler {
  @override
  final String id;

  InMemoryStorageMainHandler({this.id = inMemoryStorageHandlerId});

  @override
  List<MainHandlerFactory> create() => [];
}
