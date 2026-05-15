#!/usr/bin/env bash
# Récupère pipelines/push/tags pour chaque projet GitLab, en parallèle.
# Sortie : CSV sur stdout.
#
# Usage : GITLAB_URL=... GITLAB_TOKEN=... ./gitlab-metrics-parallel.sh > metrics.csv
# Option : PARALLEL=20 (nb de workers, défaut 20)

set -e

PARALLEL="${PARALLEL:-20}"
export GITLAB_URL GITLAB_TOKEN  # exportées pour les sous-shells xargs

echo "id,projet,pipelines,push,tags"

# Étape 1 : on liste tous les projets, page par page, sous forme "id<TAB>chemin".
page=1
while :; do
  projets=$(curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "$GITLAB_URL/api/v4/projects?per_page=100&page=$page&simple=true")
  [ "$projets" = "[]" ] && break
  echo "$projets" | jq -r '.[] | "\(.id)\t\(.path_with_namespace)"'
  page=$((page + 1))
done \
| \
# Étape 2 : workers parallèles. Tout le traitement est INLINE dans bash -c
# pour éviter le piège des fonctions exportées qui ne traversent pas les bash
# différents (macOS lance souvent /bin/bash 3.2 dans le sous-shell xargs).
tr '\n' '\0' \
| xargs -0 -P "$PARALLEL" -n 1 bash -c '
  IFS=$'"'"'\t'"'"' read -r id chemin <<< "$1"
  url="$GITLAB_URL/api/v4/projects/$id"
  # Fonction count définie LOCALEMENT dans ce sous-shell, pas de propagation.
  count() {
    curl -s -o /dev/null -D - -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$1" \
      | grep -i "^x-total:" | awk "{print \$2}" | tr -d "\r\n "
  }
  p=$(count "$url/pipelines?per_page=1")
  u=$(count "$url/events?action=pushed&per_page=1")
  t=$(count "$url/repository/tags?per_page=1")
  echo "$id,$chemin,${p:-0},${u:-0},${t:-0}"
' _