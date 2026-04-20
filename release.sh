#!/usr/bin/env bash

# Release script for Locorda RDF Suite
# Usage: ./release.sh <version>
# Example: ./release.sh 0.5.0

set -e  # Exit on error

if [ -z "$1" ]; then
  echo "Error: Version number required"
  echo "Usage: ./release.sh <version>"
  echo "Example: ./release.sh 0.5.0"
  exit 1
fi

VERSION=$1

echo "🚀 Setting version to $VERSION for all packages..."

dart run melos version \
  -V locorda_core:"$VERSION" \
  -V locorda_annotations:"$VERSION" \
  -V locorda_builder:"$VERSION" \
  -V locorda_objects:"$VERSION" \
  -V locorda_init_generator:"$VERSION" \
  -V locorda_dev:"$VERSION" \
  -V locorda_dir:"$VERSION" \
  -V locorda_drift:"$VERSION" \
  -V locorda_flutter_core:"$VERSION" \
  -V locorda_flutter:"$VERSION" \
  -V locorda_gdrive:"$VERSION" \
  -V locorda_mapping_bootstrap_generator:"$VERSION" \
  -V locorda_solid_auth:"$VERSION" \
  -V locorda_solid_auth_worker:"$VERSION" \
  -V locorda_solid_core:"$VERSION" \
  -V locorda_solid_ui:"$VERSION" \
  -V locorda_solid:"$VERSION" \
  -V locorda_ui:"$VERSION" \
  -V locorda_worker:"$VERSION" \
  -V locorda:"$VERSION"

echo "✅ Version updated to $VERSION"
echo ""
echo "Next steps:"
echo "1. Review the commit: git show HEAD"
echo "2. If changes needed: See CONTRIBUTING.md for manual tag recreation process"
echo "3. Push: git push origin main --tags"
echo "4. Publish: melos publish --no-dry-run"
