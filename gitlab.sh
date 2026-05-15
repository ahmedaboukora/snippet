#!/usr/bin/env bash
# Récupère, pour chaque projet de l'instance GitLab, le nombre de
# pipelines, de push events et de tags. Sortie : CSV sur stdout.
#
# Usage : GITLAB_URL=https://gitlab.example.com GITLAB_TOKEN=xxx ./gitlab-metrics.sh

set -e

# Fonction : appelle l'URL en HEAD et renvoie la valeur du header X-Total
# (= le total renvoyé par GitLab sans télécharger le contenu).
count() {
  curl -sI -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$1" \
    | awk 'BEGIN{IGNORECASE=1} /^x-total:/ {print $2}' | tr -d '\r\n '
}

echo "id,projet,pipelines,push,tags"

# On liste tous les projets (page par page, 100 par page).
page=1
while :; do
  projets=$(curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "$GITLAB_URL/api/v4/projects?per_page=100&page=$page&simple=true")
  # Si la page est vide ([]), on a fini.
  [ "$projets" = "[]" ] && break

  # Pour chaque projet, on récupère id et chemin, puis on interroge les 3 endpoints.
  echo "$projets" | jq -r '.[] | "\(.id)\t\(.path_with_namespace)"' \
  | while IFS=$'\t' read -r id chemin; do
      p=$(count "$GITLAB_URL/api/v4/projects/$id/pipelines?per_page=1")
      u=$(count "$GITLAB_URL/api/v4/projects/$id/events?action=pushed&per_page=1")
      t=$(count "$GITLAB_URL/api/v4/projects/$id/repository/tags?per_page=1")
      echo "$id,$chemin,${p:-0},${u:-0},${t:-0}"
    done

  page=$((page + 1))
done