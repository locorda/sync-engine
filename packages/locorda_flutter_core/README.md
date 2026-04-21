# locorda_flutter_core

Shared Flutter base types used by `locorda_flutter` and backend integration packages
(`locorda_solid`, `locorda_gdrive`, …). This package defines the contracts that
allow the main thread and backend plugins to interoperate.

> This is an internal package. Application code should depend on
> [`locorda`](../locorda) or [`locorda_flutter`](../locorda_flutter).
> Backend implementors depend on this package to satisfy `RemoteIntegration`.

## Exports

| Type | Description |
|------|-------------|
| `RemoteIntegration` | Combined `RemoteMainHandler` + `RemoteUiAdapter` — implement to create a backend plugin |
| `LocordaGraph` | Thin wrapper around `RdfGraph` used as the unit of transfer between threads |

## Implementing a custom backend

```dart
import 'package:locorda_flutter_core/locorda_flutter_core.dart';

class MyBackendIntegration implements RemoteIntegration {
  // RemoteMainHandler — main thread side (auth, UI, worker bridge)
  @override
  String get id => 'my-backend';
  // ...

  // RemoteUiAdapter — status widget integration
  // ...
}
```

## Further reading

- [locorda_flutter](../locorda_flutter) — Flutter facade built on top of this package
- [locorda_solid](../locorda_solid) — reference `RemoteIntegration` implementation
- [locorda_gdrive](../locorda_gdrive) — alternative `RemoteIntegration` implementation
