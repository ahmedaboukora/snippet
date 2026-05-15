#!/usr/bin/env bash
# Récupère pipelines/push/tags pour chaque projet GitLab, en parallèle.
# Sortie : CSV sur stdout.
#
# Usage : GITLAB_URL=... GITLAB_TOKEN=... ./gitlab-metrics-parallel.sh > metrics.csv
# Option : PARALLEL=20 (nb de workers, défaut 20)

set -e

PARALLEL="${PARALLEL:-20}"
export GITLAB_URL GITLAB_TOKEN

# Fonction qui traite UN projet (id + chemin) et affiche une ligne CSV.
# On l'exporte pour que xargs puisse l'appeler dans des sous-shells.
traiter_projet() {
  local id="$1" chemin="$2"
  count() {
    curl -sI -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$1" \
      | awk 'BEGIN{IGNORECASE=1} /^x-total:/ {print $2}' | tr -d '\r\n '
  }
  local p u t
  p=$(count "$GITLAB_URL/api/v4/projects/$id/pipelines?per_page=1")
  u=$(count "$GITLAB_URL/api/v4/projects/$id/events?action=pushed&per_page=1")
  t=$(count "$GITLAB_URL/api/v4/projects/$id/repository/tags?per_page=1")
  echo "$id,$chemin,${p:-0},${u:-0},${t:-0}"
}
export -f traiter_projet

echo "id,projet,pipelines,push,tags"

# Étape 1 : on liste tous les projets, page par page, et on les envoie
# sur stdout sous forme "id<TAB>chemin". Cette partie reste séquentielle
# (la pagination l'est par nature) mais c'est rapide : ~1500 pages seulement.
page=1
while :; do
  projets=$(curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "$GITLAB_URL/api/v4/projects?per_page=100&page=$page&simple=true")
  [ "$projets" = "[]" ] && break
  echo "$projets" | jq -r '.[] | "\(.id)\t\(.path_with_namespace)"'
  page=$((page + 1))
done \
| \
# Étape 2 : on convertit chaque ligne en string null-terminée (\0),
# puis xargs -0 envoie chaque entrée à un worker bash en parallèle.
# tr + xargs -0 est portable (macOS BSD et Linux GNU), contrairement à xargs -d.
# -P : nombre de workers concurrents
# -n 1 : une entrée par invocation
tr '\n' '\0' \
| xargs -0 -P "$PARALLEL" -n 1 -I {} bash -c '
  IFS=$'"'"'\t'"'"' read -r id chemin <<< "{}"
  traiter_projet "$id" "$chemin"
'