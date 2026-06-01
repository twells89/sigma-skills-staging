#!/usr/bin/env bash
# Package powerbi-to-sigma into a SELF-CONTAINED bundle.
#
# In the repo this skill uses symlinks (→ tableau-to-sigma/scripts) and refers to
# sibling research/ + tableau-to-sigma/refs docs — DRY, single source of truth,
# but NOT portable: a standalone download gets dangling symlinks + missing refs.
#
# This script materializes a shippable copy:
#   - dereferences every symlink in scripts/ into a real file/dir
#   - vendors the out-of-tree reference docs into refs/vendored/
#   - rewrites doc references to point at the vendored copies
#   - fails if any dangling symlink or unresolved external ref remains
#
# Usage:  ./package.sh [OUT_DIR]      (default: ./dist/powerbi-to-sigma)
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
STAGING="$(cd "$SRC/.." && pwd)"            # sigma-skills-staging
OUT="${1:-$SRC/dist/powerbi-to-sigma}"

echo "==> packaging $SRC  ->  $OUT"
rm -rf "$OUT"; mkdir -p "$OUT"

# 1. Copy the tree, DEREFERENCING symlinks (-L) so scripts/ become real files.
#    Exclude the build output itself.
( cd "$SRC" && rsync -aL --exclude 'dist' --exclude '.git' ./ "$OUT/" )

# 2. Vendor out-of-tree reference docs the skill points at.
mkdir -p "$OUT/refs/vendored"
VENDOR=(
  "$STAGING/research/dax-to-sigma-coverage.md"
  "$STAGING/research/powerbi-visual-layout.md"
  "$STAGING/tableau-to-sigma/refs/workbook-layout.md"
)
for f in "${VENDOR[@]}"; do
  if [[ -f "$f" ]]; then cp "$f" "$OUT/refs/vendored/$(basename "$f")"; echo "    vendored $(basename "$f")"
  else echo "    WARN: missing external ref $f" >&2; fi
done

# 3. Rewrite references in the packaged docs to the vendored copies.
#    Collapse the various path forms (~/sigma-skills-staging/research/..,
#    ../../research/.., research/.., tableau-to-sigma/refs/..) to refs/vendored/.
while IFS= read -r -d '' md; do
  for base in dax-to-sigma-coverage.md powerbi-visual-layout.md workbook-layout.md; do
    perl -0pi -e "s{[~A-Za-z0-9_./-]*?(?:research|refs)/${base}}{refs/vendored/${base}}g" "$md"
  done
done < <(find "$OUT" -name '*.md' -print0)

# 4. Drop the build script + dev-only SHARED note from the shippable copy.
rm -f "$OUT/package.sh" "$OUT/scripts/SHARED.md"

# 5. Verify: no dangling symlinks, no surviving out-of-tree path references.
fail=0
while IFS= read -r -d '' l; do
  [[ -e "$l" ]] || { echo "    DANGLING SYMLINK: $l" >&2; fail=1; }
done < <(find "$OUT" -type l -print0)
if grep -rEq 'sigma-skills-staging/(research|tableau-to-sigma)|\.\./\.\./(research|tableau-to-sigma)' "$OUT" 2>/dev/null; then
  echo "    WARN: unrewritten out-of-tree reference(s):" >&2
  grep -rEn 'sigma-skills-staging/(research|tableau-to-sigma)|\.\./\.\./(research|tableau-to-sigma)' "$OUT" | sed 's/^/      /' >&2
fi
[[ $fail -eq 0 ]] || { echo "==> FAILED: dangling symlinks in bundle" >&2; exit 1; }

echo "==> OK: self-contained bundle at $OUT"
echo "    scripts: $(find "$OUT/scripts" -maxdepth 1 -type f | wc -l | tr -d ' ') real files; symlinks: $(find "$OUT" -type l | wc -l | tr -d ' ')"
