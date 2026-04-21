# locorda_mapping_bootstrap_generator

Build-time code generator that embeds CRDT mapping documents (merge strategy definitions) into your application's assets at compile time.

> This generator is included automatically when you add [`locorda_dev`](../locorda_dev) as a dev dependency. You do not need to depend on this package directly.

## What it generates

For each `@RootResource`-annotated class, the generator produces a `mapping_bootstrap.g.dart` file that registers the CRDT merge contract (`.ttl` mapping document) into the app bundle so the sync engine can resolve merge strategies without a network round-trip.

## Usage

Add `locorda_dev` as a dev dependency — it aggregates this generator along with all other required builders:

```sh
flutter pub add dev:locorda_dev dev:build_runner
dart run build_runner build
```

## Further reading

- [locorda_dev](../locorda_dev) — umbrella dev dependency for all Locorda generators
- [locorda](../locorda) — getting started guide
