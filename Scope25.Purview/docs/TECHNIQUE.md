# Scope25.Purview — documentation technique

> Pour la présentation générale, voir [`README.md`](../README.md).

## Prérequis

`Test-Scope25Prerequisites` vérifie automatiquement la version de PowerShell, les modules, la stratégie d'exécution, TLS, l'accès en écriture et l'état des sessions. Il **ne peut pas** vérifier la licence, les rôles attribués ni la couverture d'indexation : ces trois-là se confirment à la main.

### Licence — la contrainte déterminante

L'inventaire de l'étape 2 (graphique circulaire, cartographie, comptes d'étiquettes) repose sur `Export-ContentExplorerData`, donc sur l'**explorateur de contenu**, que Microsoft réserve à **E5 / A5 / G5 ou au module de conformité E5**. La documentation de Microsoft précise que l'agrégation des données se poursuit côté E3, mais que les interfaces d'analyse ne sont pas accessibles sans E5.

Conséquence pratique : sur un tenant E3 ou Business Premium, l'étape 1 se déroule normalement — détecteurs importés, étiquettes publiées, guide produit, plusieurs contrôles techniques évalués — mais l'étape 2 retournera des comptes vides. Un essai Purview de 90 jours permet d'évaluer l'outil complet avant d'engager la dépense.

Piège de facturation courant : le module de conformité E5 se licencie **par utilisateur dont les données sont analysées**, pas seulement pour les administrateurs.

**Un seul compte administrateur ne suffit pas — lecture des conditions publiques.** Microsoft exige de licencier « toute personne qui accède au service ou en bénéficie, directement ou indirectement », et sa clause anti-multiplexage précise qu'utiliser un logiciel pour accéder indirectement à l'information ne réduit pas le nombre de licences requises. Scope25.Purview correspond exactement à cette description. Microsoft ajoute qu'il faut être licencié « indépendamment de l'application technique » — donc le fait que l'outil fonctionne avec une seule licence ne rend pas l'usage conforme.

À comparer avec eDiscovery (Premium), où Microsoft exempte explicitement les administrateurs et enquêteurs qui utilisent l'outil, tout en exigeant une licence pour les dépositaires. L'exemption existe quand Microsoft la veut; elle n'existe pas pour l'explorateur de contenu.

Chemins les moins coûteux : (1) essai Purview Suite de 90 jours, gratuit, 25 licences, éligible pour M365 E3 ou O365 E3 + EMS E3 sans E5 existant; (2) module complémentaire Purview Suite au mois via un partenaire, résilié après l'audit; (3) restreindre la portée avec des **unités administratives**, que l'explorateur de contenu prend en charge — licencier une population précise et n'analyser qu'elle. C'est le seul des trois qui réduit la population licenciée de façon défendable.

Faire confirmer par écrit auprès du revendeur ou de Microsoft. Ce qui précède est une lecture des conditions publiques, pas un avis contractuel.

### Exécution

| Élément | Exigence |
|---|---|
| PowerShell | 5.1 minimum; 7.4+ recommandé. Développé et testé sous **7.4.6** |
| Stratégie d'exécution | `RemoteSigned` ou moins restrictive |
| Mark-of-the-Web | `Get-ChildItem -Recurse \| Unblock-File` si le dossier vient d'Internet |
| TLS | 1.2 requis. Windows PowerShell 5.1 ne le force pas seul : `[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12` |
| Écriture | `%ProgramData%\Scope25.Purview` (journal) et Téléchargements (rapports) |

### Modules

| Module | Version | Usage |
|---|---|---|
| `ExchangeOnlineManagement` | 3.0+ | Étapes 1 et 2 — `Connect-IPPSSession` |
| `Microsoft.Graph.Authentication` | 2.0+ | Étape 2 — `Connect-Scope25Tenant` |
| `Microsoft.Graph.Identity.Partner` | 2.0+ | Facultatif — découverte GDAP |

Aucun n'est déclaré dans `RequiredModules`, délibérément : PowerShell impose `RequiredModules` à l'importation, ce qui empêchait tout poste dépourvu de ces modules d'importer Scope25.Purview — même pour lire le guide ou valider les détecteurs, qui n'en ont besoin d'aucun. La vérification se fait au point d'usage, avec un message nommant quoi installer.

### Rôles — moindre privilège

| Usage | Cmdlets | Rôle |
|---|---|---|
| Déploiement (ponctuel, écriture) | `Invoke-Scope25Setup` | Compliance Administrator |
| Inventaire (lecture) | `Get-Scope25DataMap`, `Get-Scope25SitDetection`, `Get-Scope25LabelCoverage` | Un rôle d'accès (Compliance Administrator, Compliance Data Administrator, Security Administrator ou Global Administrator) **ET** le groupe **Content Explorer List Viewer** |
| Lecture Graph | `Connect-Scope25Tenant` | Global Reader, Security Reader ou Reports Reader |
| Découverte GDAP | `Get-Scope25DelegatedTenant` | `DelegatedAdminRelationship.Read.All`, connexion distincte |

**Les deux groupes de l'inventaire ne sont pas cumulatifs.** Un rôle d'accès seul ouvre l'onglet sans afficher d'éléments; *Content Explorer List Viewer* seul ne suffit pas davantage. Il faut les deux.

**Ne pas attribuer *Content Explorer Content Viewer*.** Il autorise la lecture du contenu des fichiers analysés. Toutes les requêtes de ce module utilisent `-Aggregate` et n'en ont pas besoin. Ce rôle est aussi celui qui permet d'afficher les *noms* d'éléments en vue liste — donc si vous retirez `-Aggregate` d'une requête, vous franchissez ce seuil de privilège : à éviter sur des données personnelles.

Portées Graph : `AuditLogsQuery-Entra.Read.All`, `AuditLog.Read.All`, `Directory.Read.All`, `Reports.Read.All`. Jamais `AuditLogsQuery.Read.All`.

### Tenant

- Journalisation d'audit unifiée activée — plusieurs contrôles du domaine Incidents en dépendent.
- Contenu indexé selon les détecteurs déployés (délai d'au moins sept jours; voir README).
- MSSP : relation GDAP active, appartenance au groupe de sécurité, et application consentie dans le tenant client. `AADSTS90099` signale précisément l'absence de ce consentement.

### Installation

```powershell
Import-Module ./Scope25.Purview/Scope25.Purview.psd1
Test-Scope25Prerequisites | Format-Table -AutoSize -Wrap
```

## Tests

```powershell
pwsh -NoProfile -File tests/Test-Scope25.ps1   # suite complete
Test-Scope25SitPattern -Detailed               # motifs seulement, 24 cas
```

Couvre tout ce qui ne demande pas de tenant : diagnostics, journal et chaîne d'empreintes (y compris la détection d'une falsification), génération du guide, et les garde-fous des cmdlets qui exigent une session. **Ces tests passent sous PowerShell 7.4.6.** Les chemins qui interrogent un tenant réel ne sont pas couverts et restent à valider par qui dispose d'un environnement Microsoft 365.

## Rôles et autorisations — moindre privilège

Quatre identités distinctes plutôt qu'un compte à tout faire :

| Usage | Cmdlets | Autorisations |
|---|---|---|
| Lecture Graph | `Connect-Scope25Tenant` | `AuditLogsQuery-Entra.Read.All`, `AuditLog.Read.All`, `Directory.Read.All`, `Reports.Read.All` — jamais la portée globale `AuditLogsQuery.Read.All` |
| Découverte GDAP | `Get-Scope25DelegatedTenant` | `DelegatedAdminRelationship.Read.All` seule, connexion distincte |
| Déploiement (une fois) | `Invoke-Scope25Setup`, `Import-Scope25QuebecSIT`, `Publish-Scope25SensitivityLabels` | Compliance Administrator. Opérations d'écriture, `-WhatIf` pris en charge |
| Lecture Content Explorer | `Get-Scope25DataMap`, `Get-Scope25SitDetection`, `Get-Scope25LabelCoverage` | **Content Explorer List Viewer** seulement — pas Content Viewer : un dénombrement n'a pas besoin du contenu des fichiers |

Pour les MSSP : `Connect-Scope25Tenant -TenantId` fonctionne via GDAP en authentification **déléguée**. L'accès app-only non supervisé à travers plusieurs tenants clients demeure un point de friction non résolu de la plateforme, pas une limite de cet outil. Erreur fréquente : `AADSTS90099` signifie que l'application n'a pas encore été autorisée dans le tenant client — consentement unique requis.

## Portée de la détection

Cinq entités personnalisées; le reste s'appuie sur les types intégrés de Microsoft.

| Identifiant | Source | Ancrage |
|---|---|---|
| NAS, permis de conduire (SAAQ), passeport, compte bancaire, carte de crédit | Types intégrés Microsoft | NAS validé par somme de contrôle; carte de crédit par Luhn |
| **Numéro d'assurance maladie (RAMQ)** | Personnalisé | 4 lettres + 8 chiffres devant décoder un mois et un jour réels |
| **Chèque spécimen (transit + institution)** | Personnalisé | Norme 006 de Paiements Canada, s. 4.4.3, avec liste d'institutions validée |
| **Adresse civique du Québec** | Personnalisé | Format Poste Canada, préfixes G/H/J |
| **État civil (NIREC)** | Personnalisé | 13 chiffres. Le moins contraint des quatre : proximité resserrée à 150 caractères et mots-clés génériques retirés |

**Deux détecteurs ont été retirés**, pas rétrogradés : permis d'armes à feu (PAL) et permis récréatifs. Aucun format publié n'existe pour l'un ni pour l'autre — recherche poussée jusqu'au texte du règlement DORS/98-199 pour le PAL. Un détecteur sans ancrage structurel se déclenche surtout par coïncidence, gonfle les comptes et discrédite les détections justes. Là où un client a réellement besoin de ces identifiants, l'Exact Data Match est l'instrument approprié.

La carte de conducteur d'embarcation de plaisance ne peut pas être à confiance élevée même en principe : Transports Canada n'émet pas les cartes, des fournisseurs accrédités le font, chacun avec sa numérotation.

**Valider les motifs avant la production :**

```powershell
$data = [System.IO.File]::ReadAllBytes('<fichier_test>')
$texte = (Test-TextExtraction -FileData $data).ExtractedResults.ExtractedStreamText | Out-String
Test-DataClassification -TextToClassify $texte
```

La RAMQ publie une liste officielle de NAM fictifs destinés à la formation — c'est le bon matériel de test.

## Référentiel Loi 25

40 contrôles, 7 domaines, cités au **texte officiel consolidé de P-39.1** et au **Règlement sur l'anonymisation (A-2.1, r. 0.1)**. 38 des 40 portent une citation d'article vérifiée.

**Trois pièges d'exactitude intégrés au fichier :**

1. **Le délai de 72 heures n'existe pas dans la Loi 25** — l'art. 3.5 dit « avec diligence », sans chiffre. Le seul délai ferme est celui de 30 jours pour répondre à une demande d'accès (art. 32).
2. **L'anonymisation est permise depuis le 30 mai 2024.** Une version antérieure de ce référentiel affirmait le contraire, sur la foi d'une page de vulgarisation de la CAI restée périmée par rapport à son propre règlement. La correction est consignée dans `knownCorrections`.
3. **Les sanctions de 2 % / 10 M$** proviennent de la CAI; la disposition chiffrée se situe au-delà de la portion du texte officiel récupérable. À confirmer avant citation.

L'art. 90.1 énumère **limitativement** les manquements pouvant entraîner une sanction pécuniaire. Neuf contrôles portent un champ `sapExposure` les y rattachant — meilleure base de priorisation qu'une pondération inventée.

## Architecture

```
Scope25.Purview/
├── Scope25.Purview.psd1        # Manifeste
├── Scope25.Purview.psm1        # 18 fonctions exportées (+1 helper interne)
├── Templates/
│   ├── Quebec_SITs.xml         # 5 entités personnalisées + carte de couverture
│   ├── Scope25_Labels.json     # 4 catégories + orientations CAI par catégorie
│   ├── Loi25_Template.json     # 40 contrôles cités au texte de loi
│   └── Report_Template.html    # Gabarit unique, modes Guide et Audit
├── tests/Test-Scope25.ps1
├── docs/TECHNIQUE.md
├── README.md
└── LICENSE.txt                  # Apache 2.0
```

Aucun binaire compilé. Tout est lisible et modifiable.

## Notes de conception

- **Le rapport ne rend aucun verdict.** Les contrôles portent un constat, pas un « conforme ». Chacun comporte une case de validation destinée au réviseur.
- **Aucun score global.** Fusionner obligations techniques et organisationnelles laisserait un tenant techniquement soigné mais sans responsable désigné afficher un chiffre flatteur.
- **Découpage en deux étapes.** Rend structurellement impossible la lecture d'un zéro prématuré comme une absence de données.
- **Les UPN de boîtes aux lettres ne sont jamais énumérés.** Une liste d'employés nommés détenant des données de santé serait elle-même un document de renseignements personnels.
- **Gabarit unique pour les deux modes.** Les sections dépendantes de données restent masquées en mode Guide.

## Limites connues

- Les chemins qui interrogent un tenant réel n'ont jamais été exécutés contre un environnement Microsoft 365. Traiter la première exécution réelle comme une mise au point.
- Les noms de cmdlets Purview et leurs paramètres ont été vérifiés dans la documentation Microsoft, pas contre un tenant.
- La chaîne d'empreintes du journal rend une modification **détectable**, pas impossible. Pour une preuve devant résister à un adversaire, expédier les entrées vers un stockage inaltérable ou un SIEM.
- Couvre uniquement Microsoft 365 : ni systèmes sur place, ni applications tierces, ni papier.
