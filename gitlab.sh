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
    # GET avec body jeté (-o /dev/null) et headers récupérés (-D -).
    # On utilise grep -i (portable BSD/GNU) plutôt que awk IGNORECASE
    # qui est une extension GNU non supportée par BSD awk (macOS).
    curl -s -o /dev/null -D - -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$1" \
      | grep -i '^x-total:' \
      | awk '{print $2}' \
      | tr -d '\r\n '
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
# Étape 2 : conversion en strings null-terminées + xargs -0 (portable BSD/GNU).
# Astuce : au lieu de -I {} (qui pose problème sur BSD avec -n 1), on passe
# l'argument à bash -c via $1. Le "_" devient $0 (nom du script bidon), et
# chaque ligne lue par xargs devient $1.
tr '\n' '\0' \
| xargs -0 -P "$PARALLEL" -n 1 bash -c '
  IFS=$'"'"'\t'"'"' read -r id chemin <<< "$1"
  traiter_projet "$id" "$chemin"
' _