# Révision de l'audit — cloud-design

Fiche de préparation du jeu de rôle (« vous êtes l'ingénieur cloud qui présente sa solution »)
et de la démonstration. Les détails sont dans le [README](README.md).

## Les chiffres à connaître

| Sujet | Valeur |
|---|---|
| Région | `eu-west-3` (Paris), 2 zones |
| Cluster | EKS 1.36, 2 machines `c7i-flex.large` (3 au maximum) |
| Infrastructure | 82 ressources Terraform (pile `platform`) + 15 (pile `persistent`) |
| Coût | ≈ 0,38 $/h allumée ; 0,15 à 0,40 $ par séance ; ≈ 280 $/mois si on oubliait de détruire |
| Création / déploiement / destruction | ≈ 11 min / ≈ 2 min / ≈ 12 min |
| Images | 23 à 67 Mo ; 0 faille au dernier scan (CVE-2026-85091 trouvée puis corrigée) |
| Tests | Scénario d'audit 16/16 par l'URL publique ; isolation réseau 16/16 |
| Autoscaling | 1 → 5 copies en 15 à 30 s, retour à 1 en ≈ 2 min ; 3e machine en ≈ 35 s, retirée ≈ 4 min après la fin du besoin |

## Déroulé de la démonstration

| Question de la grille | Ce que je montre |
|---|---|
| Fichiers du dépôt | `tree -L 2` ; README, `Dockerfiles/`, `Manifests/`, `terraform/`, `Scripts/` |
| Terraform | `terraform -chdir=terraform/platform plan` (rien à changer après l'apply), `apply` |
| Services en marche | `kubectl get nodes -o wide`, `kubectl -n cloud-design get pods,svc,hpa,pvc` |
| Load balancing | `aws elbv2 describe-target-health ...` (2 machines `healthy`), `kubectl -n cloud-design get endpoints` |
| Communication sécurisée | `kubectl -n cloud-design get networkpolicy`, `Scripts/network-test.sh` |
| Fonctionnement complet | `API_TOKEN=... GATEWAY_URL=... Scripts/test-api.sh` → 16/16 |
| Dockerfiles / orchestration | Un Dockerfile Node.js (2 étapes) ; `kubectl kustomize Manifests` |
| Surveillance | `Scripts/grafana.sh` ; tableau de bord CloudWatch ; journaux CloudWatch |
| Autoscaling | `Scripts/load-test.sh pods`, puis `Scripts/load-test.sh nodes` |
| Sécurité | `curl -sv` (TLS 1.3) ; `401` sans jeton ; résultat du scan ECR |

## Les 14 questions du jeu de rôle

### 1. Qu'est-ce que le cloud, et quels sont ses avantages ?
Le cloud, c'est louer à la demande, par internet, des ressources informatiques (serveurs,
stockage, bases, réseau, services gérés) chez un fournisseur, et ne payer que ce qu'on
consomme. Avantages : pas d'achat de matériel, ressources disponibles en quelques minutes,
élasticité (on augmente ou réduit selon la charge), services gérés (le fournisseur s'occupe
du matériel, des mises à jour, de la redondance), présence mondiale, sécurité de niveau
industriel. Exemple dans ce projet : un cluster complet créé en 11 minutes, détruit en 12,
payé environ 0,38 $ de l'heure.

### 2. Pourquoi déployer dans le cloud plutôt que sur site ?
Sur site, il faut acheter et dimensionner le matériel pour le pic de charge, le maintenir, le
remplacer, assurer l'électricité et la redondance. Dans le cloud, on paie à l'usage, on
s'adapte à la charge (ici : 3e machine ajoutée automatiquement en 35 secondes), on profite de
plusieurs zones de disponibilité sans construire deux centres de données, et on décrit tout
en code (Terraform) : l'infrastructure se recrée à l'identique en une commande. Limites :
coût qui peut déraper sans surveillance, dépendance au fournisseur, données hors de chez soi.

### 3. Quelle différence entre cloud public, privé et hybride ?
**Public** : infrastructure partagée d'un fournisseur (AWS, Azure, GCP), accessible par
internet, paiement à l'usage ; c'est le cas de ce projet. **Privé** : infrastructure dédiée à
une seule organisation (son centre de données, ou OpenStack, VMware), plus de contrôle mais
tout à sa charge. **Hybride** : les deux reliés (par exemple les données sensibles sur site,
les calculs élastiques dans le cloud public, reliés par VPN ou Direct Connect).

### 4. Pourquoi AWS, et sur quels critères ?
Le sujet impose AWS. Les critères qui le confirment : le service Kubernetes géré (EKS)
continue directement le projet orchestrator ; tous les services nécessaires existent
(Cognito, API Gateway, ECR, CloudWatch) ; une région à Paris (latence, données en France) ;
un plan gratuit avec 200 $ de crédits qui protège la carte ; une documentation et une liste
de prix publiques que j'ai pu vérifier pour chaque choix.

### 5. Décrivez l'architecture et l'interaction entre ses composants.
Le client obtient un jeton auprès de **Cognito**, puis appelle **API Gateway** en HTTPS. API
Gateway vérifie le jeton (sinon `401`), limite le débit, puis transmet par un **VPC link** au
**load balancer interne**, qui répartit vers les deux machines du cluster **EKS**, sur le
NodePort 30080 ; kube-proxy choisit une copie d'**api-gateway**. api-gateway relaie
`/api/movies` vers **inventory-app**, qui lit et écrit dans **inventory-db** ; elle publie
`/api/billing` dans **RabbitMQ** ; **billing-app** consomme la file et écrit dans
**billing-db**. Les bases et RabbitMQ ont des disques EBS chiffrés. Autour : ECR pour les
images, Prometheus/Grafana et CloudWatch pour la surveillance, HPA et Cluster Autoscaler
pour l'élasticité. Tout est dans des sous-réseaux privés sur deux zones ; seule API Gateway
est publique.

### 6. Comment avez-vous géré et optimisé les coûts ?
- **Plan gratuit** d'AWS : 200 $ de crédits, la carte n'est jamais débitée.
- **Deux piles Terraform** : ce qui coûte à l'heure (cluster, machines, NAT, load balancer)
  est créé au début de chaque séance et détruit à la fin ; seuls les registres d'images et
  Cognito restent (quelques centimes par mois).
- **Inventaire automatique des 17 régions** après chaque destruction.
- **Budget AWS** avec alertes à 50 % et 100 %.
- **Choix économes**, prix vérifiés dans la liste officielle : une seule NAT, pas de clé KMS
  payante, pas de cache API Gateway, version EKS en support standard (0,10 $/h au lieu de
  0,50 $), journaux gardés 1 jour, Grafana installé dans le cluster plutôt que Managed
  Grafana, bases en conteneurs plutôt que RDS.
- **Plafonds** : 3 machines, 5 copies par service, 20 requêtes/s.
Résultat : 0,15 à 0,40 $ par séance.

### 7. Quelles mesures de sécurité et bonnes pratiques AWS ?
- Une seule entrée publique, **HTTPS (TLS 1.3)**, **authentification Cognito** (JWT) et
  limite de débit.
- **Sous-réseaux privés** et chaîne de **groupes de sécurité** : VPC link → load balancer →
  machines, rien d'autre.
- **NetworkPolicies** : tout refusé par défaut, seuls 6 échanges autorisés (prouvé par 16
  essais).
- **Chiffrement** : disques EBS chiffrés, données de l'API Kubernetes chiffrées par EKS,
  trafic entre machines chiffré par le matériel Nitro des `c7i-flex.large`.
- **Moindre privilège** : un rôle IAM par pod qui en a besoin (Pod Identity) ; Fluent Bit ne
  peut écrire que dans son groupe de journaux, le Cluster Autoscaler ne peut dimensionner
  que les machines de ce cluster.
- **Secrets** aléatoires, jamais dans git ; mots de passe PostgreSQL en SCRAM-SHA-256.
- **Conteneurs durcis** : non-root, lecture seule, capacités retirées, seccomp.
- **Scan des failles** à chaque envoi d'image (Inspector est réservé au plan payant).
- API du cluster limitée à mon adresse IP ; Grafana sans adresse publique.

### 8. Quels outils de surveillance et de journaux, et comment aident-ils ?
- **Prometheus + Grafana** : processeur, mémoire, redémarrages de chaque service, état des
  machines, copies des autoscalers. C'est grâce à eux qu'on voit qu'un service sature ou
  redémarre.
- **CloudWatch Logs** (via Fluent Bit) : un flux par service, lignes JSON découpées en
  champs, recherche par filtre ; par exemple, retrouver le moment exact où billing-app a
  enregistré une commande.
- **Journaux d'accès d'API Gateway** : chaque requête avec sa route, son statut et la raison
  d'un refus (`token not provided`, `invalid number of segments`...).
- **Tableau de bord CloudWatch** : requêtes, erreurs, latence, machines saines.
Cas réel : Grafana était tué au chargement d'un tableau de bord ; `kubectl get pod` a montré
`OOMKilled`, et la limite mémoire est passée de 256 à 512 Mo.

### 9. Quelles politiques d'autoscaling, et comment absorbent-elles la charge ?
Deux niveaux. Les **HorizontalPodAutoscalers** d'api-gateway et d'inventory-app ajoutent des
copies (1 à 5) quand le processeur dépasse 60 % de ce qui est réservé, et les retirent après
une minute de calme. Le **Cluster Autoscaler** ajoute une machine (jusqu'à 3) quand des pods
ne trouvent plus de place, et retire une machine inutile après 2 minutes. Mesuré : 1 → 5
copies en 15 à 30 secondes sous charge, retour à 1 en 2 minutes ; 3e machine en 35 secondes,
plafond de 3 respecté (« max size reached »), machine retirée après le test.

### 10. Comment avez-vous optimisé les images Docker, et avec quel effet ?
Base **Alpine** au lieu des images officielles plus lourdes ; **deux étapes** pour les
applications Node.js (les dépendances de production sont installées à part avec
`npm ci --omit=dev`, npm n'est pas dans l'image finale) ; une seule couche système ;
`.dockerignore` ; utilisateur non-root, `tini`, `HEALTHCHECK`. Résultat : 23 à 33 Mo par
image (67 Mo pour RabbitMQ) ; reconstruction des 6 images en une vingtaine de secondes grâce
au cache, contre environ 5 minutes pour la première construction et le premier envoi.

### 11. Si c'était à refaire, que changeriez-vous ?
Un nom de domaine pour avoir un certificat ACM et du HTTPS jusqu'au cluster ; une NAT par
zone ; RDS Multi-AZ pour les bases en production ; un pipeline CI/CD (tests, scan, envoi,
déploiement automatiques) ; un état Terraform dans S3 ; Karpenter à la place du Cluster
Autoscaler ; et dès le début, des valeurs de mémoire mesurées plutôt que supposées (le cas de
Grafana).

### 12. Comment faire évoluer la solution ?
**Nouveau microservice** : un dossier dans `Dockerfiles/`, un registre ECR (une ligne dans la
liste `images` de Terraform), un manifest dans `Manifests/` avec son HPA et sa NetworkPolicy,
et une route dans api-gateway ; les scripts le prennent en charge. **Plus de charge** :
relever les plafonds (machines, copies). **Autre fournisseur** : les images et les manifests
Kubernetes sont portables (AKS, GKE) ; seules les parties propres à AWS (Terraform, API
Gateway, Cognito, ECR, CloudWatch, Pod Identity) seraient à refaire avec leurs équivalents.

### 13. Quelles difficultés, et comment les avez-vous résolues ?
- Le **scan ECR ne se lançait pas** : c'est une règle du registre, pas du dépôt ; et Docker 29
  envoyait un index de provenance non scanné.
- Le scan a révélé une **faille réelle** (zlib), corrigée par `apk upgrade`.
- AWS **refuse le code 503** dans un contrôle de santé de load balancer ; j'ai utilisé le
  comportement documenté de l'ALB quand toutes les cibles sont malsaines.
- Les **disques EBS** : `lost+found` à la racine (PostgreSQL refusait d'initialiser) et
  propriété root (résolu par `fsGroup`).
- **Grafana OOMKilled** et une source Alertmanager fantôme.
- Les **coûts** : chaque séance se termine par une destruction vérifiée dans toutes les
  régions.
Méthode : lire l'erreur en entier, vérifier dans la documentation officielle, mesurer avant
de conclure.

### 14. Comment avez-vous assuré la clarté et la complétude de la documentation ?
Le README suit la grille : architecture avec schémas, coûts chiffrés et sourcés,
prérequis, installation pas à pas, utilisation, sécurité, surveillance, autoscaling,
scénario d'audit avec les commandes, choix et alternatives, dépannage des problèmes
réellement rencontrés. Les résultats cités ont été mesurés sur l'infrastructure réelle ;
chaque fichier de configuration explique ses choix en commentaire ; cette fiche résume le
tout pour l'oral.
