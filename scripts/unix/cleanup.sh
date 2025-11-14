#!/usr/bin/env bash
#
# JSH Cleanup Utility
# Cleans sync-conflict files, broken symlinks, brew cache, and system caches
#

set -euo pipefail

ROOT_DIR="${1:-$HOME/.jsh}"

echo "🧹 JSH Cleanup Utility"
echo "====================="
echo ""

# 1. Sync-conflict files
echo "1️⃣  Checking for sync-conflict files in .jsh directory..."
PATTERNS=("*.sync-conflict-*" "*conflicted copy*" "*.conflict" "*-conflict-*")
CONFLICT_FILES=""
for pattern in "${PATTERNS[@]}"; do
  FOUND=$(find "$ROOT_DIR" -type f -iname "$pattern" 2>/dev/null || true)
  if [ -n "$FOUND" ]; then
    CONFLICT_FILES="${CONFLICT_FILES}${FOUND}"$'\n'
  fi
done
CONFLICT_FILES=$(echo "$CONFLICT_FILES" | sed '/^$/d')

if [ -z "$CONFLICT_FILES" ]; then
  echo "✅ No sync-conflict files found"
  echo ""
else
  COUNT=$(echo "$CONFLICT_FILES" | wc -l | tr -d ' ')
  echo "🔗 Found $COUNT sync-conflict file(s):"
  echo "$CONFLICT_FILES" | while IFS= read -r file; do
    SIZE=$(du -h "$file" 2>/dev/null | cut -f1 || echo "?")
    echo "  📄 $file ($SIZE)"
  done
  echo ""
  read -p "Remove sync-conflict files? [Y/n] " -n 1 -r REPLY
  echo ""
  REPLY=${REPLY:-Y}
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "$CONFLICT_FILES" | while IFS= read -r file; do
      echo "  🗑️  Removing: $file"
      rm -f "$file"
    done
    echo "✅ Removed sync-conflict files"
  else
    echo "⏭️ Skipped sync-conflict cleanup"
  fi
  echo ""
fi

# 2. Broken symlinks in home directory
echo "2️⃣  Checking for broken symlinks in home directory..."
BROKEN_LINKS=$(find ~ -maxdepth 1 -type l ! -exec test -e {} \; -print 2>/dev/null || true)
if [ -z "$BROKEN_LINKS" ]; then
  echo "✅ No broken symlinks found"
  echo ""
else
  echo "🔗 Found broken symlinks:"
  echo "$BROKEN_LINKS" | while IFS= read -r link; do
    echo "  ❌ $link"
  done
  echo ""
  read -p "Remove broken symlinks? [Y/n] " -n 1 -r REPLY
  echo ""
  REPLY=${REPLY:-Y}
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "$BROKEN_LINKS" | while IFS= read -r link; do
      echo "  🗑️  Removing: $link"
      rm "$link"
    done
    echo "✅ Removed broken symlinks"
  else
    echo "⏭️ Skipped broken symlink cleanup"
  fi
  echo ""
fi

# 3. Homebrew cleanup
echo "3️⃣  Homebrew cleanup (remove old versions and downloads)..."
read -p "Run brew cleanup? [Y/n] " -n 1 -r REPLY
echo ""
REPLY=${REPLY:-Y}
if [[ $REPLY =~ ^[Yy]$ ]]; then
  echo "🍺 Running brew cleanup..."
  brew cleanup -s 2>&1 | head -n 20
  echo "✅ Brew cleanup complete"
else
  echo "⏭️ Skipped brew cleanup"
fi
echo ""

# 4. System caches
echo "4️⃣  System cache cleanup..."
CACHE_DIRS=(
  "$HOME/Library/Caches/Homebrew"
  "$HOME/.cache"
  "$HOME/Library/Logs"
)
TOTAL_SIZE=0
for cache_dir in "${CACHE_DIRS[@]}"; do
  if [ -d "$cache_dir" ]; then
    SIZE=$(du -sh "$cache_dir" 2>/dev/null | cut -f1 || echo "0")
    echo "  📦 $cache_dir ($SIZE)"
    CACHE_SIZE=$(du -sk "$cache_dir" 2>/dev/null | cut -f1 || echo "0")
    TOTAL_SIZE=$((TOTAL_SIZE + CACHE_SIZE))
  fi
done
if [ $TOTAL_SIZE -gt 0 ]; then
  TOTAL_SIZE_HUMAN=$(echo "$TOTAL_SIZE" | awk '{sum=$1/1024; if (sum > 1024) printf "%.1fG\n", sum/1024; else printf "%.1fM\n", sum}')
  echo ""
  echo "  Total: $TOTAL_SIZE_HUMAN"
  echo ""
  read -p "Clear system caches? [Y/n] " -n 1 -r REPLY
  echo ""
  REPLY=${REPLY:-Y}
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    for cache_dir in "${CACHE_DIRS[@]}"; do
      if [ -d "$cache_dir" ] && [ -n "$cache_dir" ]; then
        echo "  🗑️  Clearing $cache_dir..."
        rm -rf "${cache_dir:?}"/* 2>/dev/null || true
      fi
    done
    echo "✅ System caches cleared"
  else
    echo "⏭️ Skipped cache cleanup"
  fi
else
  echo "✅ No significant cache files found"
fi
echo ""

echo "🎉 Cleanup complete!"
