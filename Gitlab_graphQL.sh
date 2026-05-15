#!/usr/bin/env bash
# Récupère pipelines et tags de tous les projets via GraphQL (1 appel = 100 projets).
# Les push events ne sont pas exposés en GraphQL → on les récupère en REST en parallèle.
#
# Usage : GITLAB_URL=... GITLAB_TOKEN=... ./gitlab-metrics-graphql.sh > metrics.csv

set -e

# La requête GraphQL : on demande 100 projets à la fois avec leurs compteurs.
LIRE_REQUETE='query($cursor: String) {
  projects(first: 100, after: $cursor) {
    pageInfo { endCursor hasNextPage }
    nodes {
      id
      fullPath
      pipelines { count }
      repository { tagNames }
    }
  }
}'

# Fonction REST pour le seul compteur manquant en GraphQL : les push events.
compter_push() {
  curl -sI -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "$GITLAB_URL/api/v4/projects/$1/events?action=pushed&per_page=1" \
    | awk 'BEGIN{IGNORECASE=1} /^x-total:/ {print $2}' | tr -d '\r\n '
}
export -f compter_push
export GITLAB_URL GITLAB_TOKEN

echo "id,projet,pipelines,push,tags"

cursor="null"
while :; do
  # Construction du payload JSON avec jq (sûr pour échapper les variables).
  payload=$(jq -nc --arg q "$LIRE_REQUETE" --arg c "$cursor" \
    '{query: $q, variables: {cursor: (if $c == "null" then null else $c end)}}')

  reponse=$(curl -s -X POST \
    -H "Authorization: Bearer $GITLAB_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    "$GITLAB_URL/api/graphql")

  # Pour chaque projet de la page, on sort id, chemin, pipelines, nb tags.
  # On extrait l'ID numérique depuis le Global ID GraphQL ("gid://gitlab/Project/42").
  echo "$reponse" | jq -r '
    .data.projects.nodes[] |
    [(.id | sub("gid://gitlab/Project/"; "")),
     .fullPath,
     .pipelines.count,
     (.repository.tagNames | length)] |
    @tsv' \
  | while IFS=$'\t' read -r id chemin pipelines tags; do
      # Push events en parallèle = un appel REST par projet, mais 20 en simultané.
      push=$(compter_push "$id")
      echo "$id,$chemin,$pipelines,${push:-0},$tags"
    done

  # Pagination : on lit le curseur suivant, ou on sort.
  has_next=$(echo "$reponse" | jq -r '.data.projects.pageInfo.hasNextPage')
  [ "$has_next" != "true" ] && break
  cursor=$(echo "$reponse" | jq -r '.data.projects.pageInfo.endCursor')
done