Bonne question — en regardant ton tableau, je vois que tu mélanges trois choses : ce qui **déclenche** un pipeline, ce qui **se passe pendant/après** un pipeline, et des évènements connexes (tags, commentaires) qui ne sont pas vraiment des évènements pipeline mais des évènements repo. Je te propose de séparer ces dimensions, ça aide à ne rien oublier.

**Évènements qui déclenchent un pipeline (sources)**

GitLab distingue ces sources de pipeline (champ `source` dans l'API) :
- Push sur la branche par défaut ✅ (tu l'as)
- Push sur une branche non-défaut (feature branch) — souvent traité différemment car volume énorme
- Pipeline de tag ✅
- **Pipeline de Merge Request** — c'est probablement le gros manquant de ton tableau. C'est l'évènement le plus fréquent dans la plupart des workflows GitLab.
- Merge train (si tu utilises les merge trains)
- Pipeline programmé (`schedule`) — cron, typiquement scans de sécu nocturnes
- Pipeline manuel (déclenché via UI ou API)
- Trigger token (déclenchement externe)
- Pipeline parent-enfant / multi-projet (downstream)
- Pipeline d'API (job token)

**Évènements de cycle de vie d'un pipeline**

Sur le webhook `Pipeline events`, GitLab te notifie sur les changements d'état :
- created / pending / running
- success
- **failed** — quasi obligatoire pour de l'alerting
- canceled
- skipped
- manual (action manuelle en attente)

Pour la plupart des intégrations, "success" et "failed" sur la branche par défaut suffisent ; les autres états sont du bruit.

**Évènements de job (granularité plus fine)**

Si tu veux observer ce qui se passe à l'intérieur du pipeline (utile pour de la conformité ou du temps de cycle) : job created, started, success, failed, retry, action manuelle déclenchée.

**Évènements de déploiement (à côté du pipeline)**

- Promote ✅
- Demote ✅
- Rollback (à rajouter selon ton workflow)
- Environment stopped / created
- Deployment success / failed

**Évènements de sécurité**

- Drift / vuln détectée ✅
- Vulnérabilité dismissed / resolved / confirmed (workflow de remédiation)
- Container scanning, SAST, DAST, secret detection — si tu veux les distinguer par type
- License compliance

**Évènements repo connexes (pas vraiment "pipeline" mais souvent dans le même flux)**

- Tag créé ✅
- Commentaire ✅
- **MR opened / merged / closed / approved** — gros gap si tu fais de la gouvernance code
- Release publiée

---

**Mon conseil pratique** : avant de figer le tableau, demande-toi pour chaque évènement *qui le consomme et pour quoi faire*. Tu vas vite voir que :
- Les pipelines de feature branch génèrent un volume énorme pour peu de valeur business
- Les pipelines de MR sont critiques (gating, qualité)
- Le `failed` sur main est non négociable
- Les évènements de déploiement (promote/demote/rollback) intéressent surtout les équipes ops/SRE
- Les évènements de sécu intéressent surtout RSSI/AppSec

Si tu veux, partage-moi le use case côté consommateurs (web service / MQ) et je peux t'aider à arbitrer ce qui mérite d'être publié et ce qui peut être filtré en amont.

Pour la plupart, ça passe par les **webhooks GitLab** (Settings > Webhooks, niveau projet ou groupe). Voici concrètement comment chacun s'obtient.

**1. Push sur la branche par défaut**

Cocher `Push events` dans le webhook. GitLab envoie un évènement pour *tout* push (toutes branches), donc deux options pour filtrer :
- Côté GitLab : utiliser le champ `Push events branch filter` (wildcard ou regex) dans la config du webhook → tu mets `main` (et/ou `master`). Plus propre, moins de bruit.
- Côté consommateur : filtrer sur `ref == "refs/heads/<default_branch>"` dans le payload. Tu peux récupérer la default branch via l'API projet (`/projects/:id` → champ `default_branch`).

À noter : par défaut, un push qui modifie plus de 3 branches ne déclenche aucun webhook, c'est rarement bloquant mais à connaître.

**2. Event de pipeline de tag**

Cocher `Pipeline events`. Ce webhook capture **tous** les pipelines (push, MR, tag, schedule, manuel). Pour isoler les pipelines de tag :
- Filtrer côté consommateur sur `object_attributes.tag == true`, ou sur `object_attributes.source == "push"` combiné avec `ref` commençant par `refs/tags/`.

Il n'y a pas de filtre natif dans GitLab pour ne recevoir *que* les pipelines de tag, donc le tri se fait en aval.

**3. Event de tag**

Cocher `Tag push events` — c'est un webhook **séparé** du push events. Il se déclenche à la création ou suppression d'un tag (distinguer via `before`/`after` : si `after == "0000..."`, c'est une suppression).

**4. Event de commentaire**

Cocher `Comments` (alias "Note events"). Un seul webhook couvre tous les commentaires : commits, MR, issues, snippets, threads de code. Pour distinguer le type, regarder `object_attributes.noteable_type` (`Commit`, `MergeRequest`, `Issue`, `Snippet`). Depuis GitLab 16.11, les édits de commentaires déclenchent aussi le webhook.

**5. Event de drift (vuln)**

Bonne nouvelle : depuis **GitLab 17.11**, les évènements de vulnérabilité sont **GA** comme webhook natif. Cocher `Vulnerability events` (Ultimate). Le webhook se déclenche quand :
- une vulnérabilité est créée,
- son statut change (`detected` → `confirmed` / `dismissed` / `resolved`),
- une issue est liée à une vulnérabilité.

Payload : `object_kind: "vulnerability"` avec sévérité, CVSS, identifiers (CVE), location (fichier/dépendance), etc.

⚠️ Gotchas :
- Ultimate uniquement.
- Au moment de la sortie, il y avait des bugs sur l'activation au niveau **group webhook** — à vérifier sur ta version.
- "Drift" peut aussi vouloir dire *Terraform state drift* ou *config drift conteneur*. Ce webhook couvre les vulns détectées par les scans GitLab (SAST, DAST, dependency, container, secret). Si ton "drift" c'est autre chose, dis-moi.

**6. Events de promote / demote**

Là c'est moins direct : GitLab n'a **pas** d'évènements `promote` ou `demote` en tant que tels. Ce qui existe :
- Webhook `Deployment events` → se déclenche quand un déploiement démarre, réussit, échoue ou est annulé, avec le champ `environment` dans le payload.

Pour reconstruire promote/demote, tu maintiens côté consommateur une hiérarchie d'environnements (`dev < staging < prod`) et tu compares :
- Le déploiement précédent de la même release/SHA → si la cible est plus haute = **promote**, plus basse = **demote** (ou rollback).
- Alternative : si tu utilises les protected environments avec deployment approvals, tu peux baser ta logique sur les transitions d'environnement.

C'est typiquement un évènement *dérivé* qui se calcule dans ta couche d'intégration, pas un évènement source GitLab.

---

**Synthèse pour ton tableau**

| Évènement métier | Webhook GitLab | Filtre/transformation |
|---|---|---|
| Push branche défaut | `Push events` | Branch filter sur default_branch |
| Pipeline de tag | `Pipeline events` | `object_attributes.tag == true` |
| Tag | `Tag push events` | Distinguer create/delete via `after` |
| Commentaire | `Comments` | Optionnel : filtrer sur `noteable_type` |
| Drift (vuln) | `Vulnerability events` (≥17.11, Ultimate) | Filtrer sur `state` ou `severity` |
| Promote/Demote | `Deployment events` | Logique dérivée côté conso (hiérarchie env) |

Deux questions pour aller plus loin :
1. Tu es sur GitLab.com ou self-managed ? (impacte la version dispo pour les vulnerability events)
2. Tu configures les webhooks au niveau projet ou groupe ? À l'échelle, les **group webhooks** évitent de devoir reconfigurer chaque projet, mais ils ont quelques limitations.

Parfait, ça verrouille pas mal de choses. Voici ce qui change concrètement en GitLab 18 pour ton design.

**Tout ce qui te bloquait potentiellement est dispo**

- **Vulnerability events** : GA depuis 17.11, donc OK chez toi sans feature flag.
- **Epic events** au niveau group : GA en 18.1 — utile si la gouvernance Epic fait partie de ton scope.
- **Idempotency-Key header** (depuis 17.4) : présent sur chaque event. **Utilise-le côté MQ** comme clé de dédup, c'est cleaner que `X-Gitlab-Webhook-UUID`.
- **Custom headers** (jusqu'à 20 par webhook) GA depuis 17.0 : pratique pour ajouter du routing metadata (`X-Event-Source: gitlab-prod`, `X-Tenant: ...`) sans avoir à parser le payload côté conso.
- **Custom webhook template** GA depuis 17.0 : tu peux **reformater le payload** au moment de l'envoi par GitLab. Très intéressant si ton MQ attend un format normalisé (CloudEvents par ex.) — tu uniformises au plus près de la source plutôt qu'en aval.

**À vérifier sur ta version mineure exacte**

- **`auto_disabling_webhooks`** : sur self-managed, les changements de self-healing (16.6 → backoff jusqu'à 1 jour) sont derrière l'ops flag auto_disabling_webhooks. Demande à ton admin si c'est activé chez vous, ça change le comportement de récupération après panne.
- **`custom_webhook_template_serialization`** : JSON serialization des valeurs interpolées dans les custom templates a été introduite en 18.4 (flag off), GA en 18.6, flag retiré en 18.10. Si tu pars sur les custom templates et que tu es < 18.6, fais gaffe : les valeurs complexes (objets, tableaux) ne se sérialisent pas en JSON par défaut.
- **Approval reset metadata** (18.6) : les payloads de MR distinguent maintenant les resets d'approbation système (system: true, system_action: approvals_reset_on_push) des actions utilisateur. Utile si tu fais de l'audit / conformité sur les MR.

**Le seul vrai trou en GitLab 18**

**Signing token HMAC-SHA256** : introduit en GitLab 19.0, calcule une signature HMAC-SHA256 sur le payload, permettant au destinataire de vérifier authenticité et intégrité — suit la spec Standard Webhooks (headers webhook-id, webhook-timestamp, webhook-signature). **Pas dispo chez vous**. Tu restes sur le `Secret token` classique transmis en clair dans le header `X-Gitlab-Token`.

**Implications pratiques** :
- Ton endpoint d'ingestion doit être en HTTPS strict (sinon le secret token fuite).
- Si ton réseau d'ingestion n'est pas full trusted, tu n'as pas de vérification d'intégrité du payload. Quelqu'un qui intercepte peut forger.
- À mettre dans la roadmap : **migration vers signing token quand tu passeras en GitLab 19** (probablement courant 2026). Anticipe le support des deux modes côté consommateur pour faire la transition sans downtime.

**Recap pour ton design en GitLab 18**

| Décision | Recommandation |
|---|---|
| Niveau de configuration | Group webhook sur top-level group |
| Auth | Secret token + HTTPS + IP allowlist si possible |
| Dédup | Header `Idempotency-Key` comme clé MQ |
| Format payload | Custom webhook template → format normalisé (CloudEvents recommandé) |
| Routing | Custom headers (`X-Event-Source`, `X-Tenant`, etc.) |
| Résilience | MQ avec retry + DLQ côté conso (GitLab ne retry pas) |
| Monitoring | Alerte sur webhook en état `Disabled` ou `Temporarily disabled` |
| Roadmap | Plan de migration vers signing token pour GitLab 19 |

Tu veux qu'on creuse la structure du payload normalisé (CloudEvents vs format custom), ou la stratégie de monitoring des webhooks ?