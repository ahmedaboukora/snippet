# Remplace 42 par un ID de projet réel que tu vois sur l'instance
PROJECT_ID=42

echo "--- Test 1 : headers bruts ---"
curl -s -o /dev/null -D - -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/projects/$PROJECT_ID/pipelines?per_page=1"

echo "--- Test 2 : grep seul ---"
curl -s -o /dev/null -D - -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/projects/$PROJECT_ID/pipelines?per_page=1" \
  | grep -i '^x-total:'

echo "--- Test 3 : chaîne complète ---"
result=$(curl -s -o /dev/null -D - -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/projects/$PROJECT_ID/pipelines?per_page=1" \
  | grep -i '^x-total:' | awk '{print $2}' | tr -d '\r\n ')
echo "[$result]"