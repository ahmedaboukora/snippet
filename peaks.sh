#!/usr/bin/env bash
# Calcule, sur les N derniers jours, le pic journalier (toute l'instance)
# de pipelines créés, de push (sur branches) et de tags poussés.
#
# Usage : GITLAB_URL=... GITLAB_TOKEN=... ./gitlab-peaks.sh
# Options : JOURS=90 (fenêtre, défaut 90), PARALLEL=20 (workers, défaut 20)

set -e

PARALLEL="${PARALLEL:-20}"
JOURS="${JOURS:-90}"
export GITLAB_URL GITLAB_TOKEN

# Date de début (BSD date sur macOS, GNU date sur Linux).
if date -v-${JOURS}d +%Y-%m-%d >/dev/null 2>&1; then
  DEPUIS=$(date -v-${JOURS}d +%Y-%m-%d)
else
  DEPUIS=$(date -d "${JOURS} days ago" +%Y-%m-%d)
fi
export DEPUIS

echo "Collecte depuis $DEPUIS (fenêtre $JOURS jours)..." >&2

# Fichiers de travail (le DUMP est gardé après le run pour analyse offline).
WORKER=$(mktemp)
PROJETS=$(mktemp)
DUMP="gitlab-peaks-dump.tsv"
trap 'rm -f "$WORKER" "$PROJETS"' EXIT
: > "$DUMP"

# -----------------------------------------------------------------------------
# Le worker : pour un projet, dump sur stdout des lignes "type<TAB>YYYY-MM-DD".
# On le met dans un fichier séparé pour éviter l'enfer des escapes jq dans
# un bash -c en ligne.
# -----------------------------------------------------------------------------
cat > "$WORKER" << 'WORKEREOF'
#!/usr/bin/env bash
id="$1"
url="$GITLAB_URL/api/v4/projects/$id"

# Pipelines créés dans la fenêtre.
# `updated_after` est le seul filtre date dispo ici ; on filtre côté client
# sur created_at pour la date du jour.
page=1
while :; do
  rep=$(curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "$url/pipelines?per_page=100&page=$page&updated_after=$DEPUIS") || break
  [ "$rep" = "[]" ] || [ -z "$rep" ] && break
  echo "$rep" | jq -r '.[] | "pipeline\t" + (.created_at[0:10])' 2>/dev/null
  nb=$(echo "$rep" | jq 'length' 2>/dev/null)
  if [ -z "$nb" ] || [ "$nb" -lt 100 ]; then break; fi
  page=$((page + 1))
done

# Events "pushed" dans la fenêtre. Ils couvrent à la fois push de branches
# et push de tags : on distingue avec push_data.ref_type.
page=1
while :; do
  rep=$(curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "$url/events?action=pushed&per_page=100&page=$page&after=$DEPUIS") || break
  [ "$rep" = "[]" ] || [ -z "$rep" ] && break
  echo "$rep" | jq -r '
    .[] |
    (if .push_data.ref_type == "tag" then "tag" else "push" end)
    + "\t" + (.created_at[0:10])
  ' 2>/dev/null
  nb=$(echo "$rep" | jq 'length' 2>/dev/null)
  if [ -z "$nb" ] || [ "$nb" -lt 100 ]; then break; fi
  page=$((page + 1))
done
WORKEREOF
chmod +x "$WORKER"

# -----------------------------------------------------------------------------
# Étape 1 : lister tous les projets.
# -----------------------------------------------------------------------------
page=1
while :; do
  projets=$(curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "$GITLAB_URL/api/v4/projects?per_page=100&page=$page&simple=true")
  [ "$projets" = "[]" ] && break
  echo "$projets" | jq -r '.[].id' >> "$PROJETS"
  page=$((page + 1))
done
nb_projets=$(wc -l < "$PROJETS" | tr -d ' ')
echo "$nb_projets projets à scanner avec $PARALLEL workers..." >&2

# -----------------------------------------------------------------------------
# Étape 2 : parallélisation. Chaque worker écrit ses lignes sur son stdout ;
# xargs concatène tout vers le fichier DUMP. Les écritures < 4096 octets sont
# atomiques au niveau OS, donc pas d'entrelacement sur des lignes courtes.
# -----------------------------------------------------------------------------
tr '\n' '\0' < "$PROJETS" \
| xargs -0 -P "$PARALLEL" -n 1 "$WORKER" >> "$DUMP"

echo "Collecte terminée ($(wc -l < "$DUMP" | tr -d ' ') événements). Agrégation..." >&2

# -----------------------------------------------------------------------------
# Étape 3 : agrégation. Pour chaque type, on compte par jour et on prend le max.
# -----------------------------------------------------------------------------
echo ""
echo "=== Pic journalier sur $JOURS jours (depuis $DEPUIS) ==="
printf "%-10s | %8s | %s\n" "Type" "Count" "Date"
printf "%-10s-+-%8s-+-%s\n" "----------" "--------" "----------"
for type in pipeline push tag; do
  ligne=$(awk -F'\t' -v t="$type" '$1==t {print $2}' "$DUMP" \
    | sort | uniq -c | sort -rn | head -n1)
  count=$(echo "$ligne" | awk '{print $1}')
  date=$(echo "$ligne" | awk '{print $2}')
  printf "%-10s | %8s | %s\n" "$type" "${count:-0}" "${date:-N/A}"
done

echo ""
echo "Détail brut conservé dans $DUMP (format: type<TAB>date)." >&2
echo "Pour distribution complète : awk -F'\\t' '\$1==\"push\"' $DUMP | cut -f2 | sort | uniq -c | sort -rn" >&2