# Homepage Integration Guide

This document describes how to integrate sync-engine content into the `locorda/locorda` homepage repository for deployment at `locorda.dev`.

## Overview

When sync-engine content changes (vocabularies, mappings, example app), it triggers the homepage deployment via GitHub's repository dispatch API. The homepage workflow then:

1. Checks out both `locorda/locorda` and `locorda/sync-engine`
2. Builds the homepage
3. Builds sync-engine artifacts (Flutter app, copies vocabularies/mappings)
4. Combines everything into the correct directory structure
5. Deploys to GitHub Pages at `locorda.dev`

## Setup in `locorda/locorda` Repository

### 1. Add Personal Access Token Secret

In `locorda/sync-engine` repository settings:
1. Go to Settings → Secrets and variables → Actions
2. Add new repository secret: `HOMEPAGE_DISPATCH_TOKEN`
3. Value: A fine-grained PAT with:
   - Repository access: Only `locorda/locorda`
   - Permissions: Actions (read and write)

### 2. Modify Homepage Pages Workflow

Add to the existing `.github/workflows/pages.yml` (or similar) in `locorda/locorda`:

```yaml
name: Deploy GitHub Pages

on:
  push:
    branches: [main]
  repository_dispatch:
    types: [sync-engine-update]  # ← Add this

jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
      pages: write
    
    steps:
      # 1. Checkout homepage
      - name: Checkout homepage repository
        uses: actions/checkout@v4
      
      # 2. Checkout sync-engine
      - name: Checkout sync-engine repository
        uses: actions/checkout@v4
        with:
          repository: locorda/sync-engine
          path: sync-engine
      
      # 3. Setup tools
      - name: Setup Pages
        uses: actions/configure-pages@v5
      
      - name: Setup Flutter
        uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.38.7'
          cache: true
      
      - name: Setup Dart/Melos
        run: |
          dart pub global activate melos
      
      # 4. Build homepage
      - name: Build homepage
        run: |
          # Your homepage build steps here
          # Output to: dist/ (or whatever your build dir is)
      
      # 5. Build sync-engine artifacts
      - name: Bootstrap sync-engine workspace
        working-directory: sync-engine
        run: melos bootstrap
      
      - name: Build sync-engine Flutter example app
        working-directory: sync-engine/packages/locorda/example/personal_notes_app
        run: flutter build web --release --base-href /example/personal_notes_app/
      
      - name: Integrate sync-engine content into site
        run: |
          # Create directory structure (directly under root, not under /sync-engine/)
          mkdir -p dist/vocab
          mkdir -p dist/mappings
          mkdir -p dist/example/personal_notes_app/mappings
          mkdir -p dist/example/personal_notes_app/auth
          
          # Copy vocabularies directly to /vocab/
          cp sync-engine/spec/vocabularies/* dist/vocab/
          
          # Copy mappings directly to /mappings/
          cp sync-engine/spec/mappings/* dist/mappings/
          
          # Copy built Flutter app directly to /example/
          cp -r sync-engine/packages/locorda/example/personal_notes_app/build/web/* dist/example/personal_notes_app/
          
          # Copy example-specific mappings
          cp sync-engine/packages/locorda/example/personal_notes_app/assets/contracts/mappings/* dist/example/personal_notes_app/mappings/
          
          # Copy auth configuration
          cp sync-engine/packages/locorda/example/personal_notes_app/assets/contracts/auth/client-config.json dist/example/personal_notes_app/auth/
      
      # 6. Deploy combined site
      - name: Upload artifact
        uses: actions/upload-pages-artifact@v3
        with:
          path: dist
      
      - name: Deploy to GitHub Pages
        id: deployment
        uses: actions/deploy-pages@v4
```

## Resulting URL Structure

After deployment, content will be available at:

```
locorda.dev/                                              # Homepage
├── rdf/                                                  # RDF section
├── sync-engine/                                          # Sync Engine docs/landing (homepage managed)
├── vocab/                                                # ← Vocabularies (*.ttl) - DIRECTLY under root!
│   ├── crdt-algorithms.ttl
│   ├── crdt-mechanics.ttl
│   ├── idx.ttl
│   └── sync.ttl
├── mappings/                                             # ← Core mappings (*.ttl) - DIRECTLY under root!
│   └── core-v1.ttl
├── example/personal_notes_app/                           # ← Example Flutter app - DIRECTLY under root!
│   ├── mappings/                                         # App-specific mappings
│   │   ├── category-v1.ttl
│   │   └── note-v1.ttl
│   ├── auth/
│   │   └── client-config.json
│   └── [flutter web app files]
└── chat-essence/                                         # Future: other apps
```

## w3id.org Redirects

The w3id.org redirects remain unchanged (exactly as before):

```
https://w3id.org/solid-crdt-sync/vocab/crdt-algorithms
  → https://locorda.dev/vocab/crdt-algorithms.ttl

https://w3id.org/solid-crdt-sync/mappings/core-v1
  → https://locorda.dev/mappings/core-v1.ttl
```

**No changes needed to existing w3id.org configuration!** ✅

## Testing

1. After setup, push a change to `sync-engine/spec/vocabularies/` or the example app
2. Check Actions in `locorda/sync-engine` - should see trigger workflow run
3. Check Actions in `locorda/locorda` - should see deployment triggered
4. Verify content at:
   - `locorda.dev/vocab/crdt-algorithms.ttl`
   - `locorda.dev/mappings/core-v1.ttl`
   - `locorda.dev/example/personal_notes_app/`

## Troubleshooting

**Trigger doesn't work:**
- Verify `HOMEPAGE_DISPATCH_TOKEN` secret exists in sync-engine repo
- Check token has correct permissions
- Look for curl errors in trigger workflow logs

**Content missing after deployment:**
- Check paths in homepage workflow match this guide
- Verify Flutter base-href matches deployment path
- Check homepage's `dist/` directory structure before upload

**Old content still deployed:**
- Clear GitHub Pages cache by making a trivial commit to homepage
- Check that both workflows completed successfully
