# Locorda Examples

Two example Flutter apps demonstrating different levels of Locorda integration.

---

## [minimal/](minimal/)

A minimal task-sync app — the fastest path from zero to syncing.

- Plain Dart objects with `@RootResource` annotations
- Offline-first, conflict-free sync across devices
- `locorda_dir` as a local-directory remote (easy to swap for Solid Pods or Google Drive)
- Repository pattern: clean separation of UI, storage, and sync

→ Start here if you are new to Locorda.

---

## [personal_notes_app/](personal_notes_app/)

A full-featured notes app showing production-ready patterns.

- Drift (SQLite) as the local persistence layer
- Worker-isolate architecture for non-blocking sync
- Solid Pod integration (with `locorda_solid`)
- Service layer, repository layer, and UI fully decoupled from sync details

→ Use this as a reference for real-world app architecture.

---

## Quick start

```bash
# Run the minimal example
cd minimal
flutter run

# Run the personal notes app
cd personal_notes_app
flutter run
```
