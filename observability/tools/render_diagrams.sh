#!/bin/bash
# Pre-render the diagrams that GitHub cannot draw itself.
#
# Most diagrams in this repo are inline mermaid in the Markdown, which GitHub
# renders directly and which stays diffable. The deployment view is the
# exception: it uses real Google Cloud icons, and those come from an Iconify
# icon pack that has to be registered with a JavaScript call. GitHub's Markdown
# renderer has no mechanism for running that, so the icons would come out blank
# there. Rendering it here and committing the SVG is the only way to get them.
#
# The SVG is self-contained -- the icons are inlined as paths, with no external
# references -- so it displays anywhere an image does.
#
#   tools/render_diagrams.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIAG="${HERE}/../docs/diagrams"

# Chromium needs these flags in a container or on a VM without a sandbox.
PPTR=$(mktemp --suffix=.json)
printf '{"args":["--no-sandbox","--disable-setuid-sandbox","--disable-dev-shm-usage"]}' > "$PPTR"
trap 'rm -f "$PPTR"' EXIT

for f in "${DIAG}"/*.mmd; do
  out="${f%.mmd}.svg"
  echo "  $(basename "$f") -> $(basename "$out")"
  npx --yes @mermaid-js/mermaid-cli \
    -i "$f" -o "$out" -p "$PPTR" \
    --iconPacks @iconify-json/gcp \
    --backgroundColor white >/dev/null
done
echo "done"
