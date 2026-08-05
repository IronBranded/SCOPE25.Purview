# Scope25.Purview

**Quelles données personnelles votre organisation a-t-elle, et où sont-elles?**

Outil libre et gratuit qui fait l'inventaire des renseignements personnels dans Microsoft 365 et les relie aux obligations de la **Loi 25**. Utile avant un incident pour être prêt, et après un incident pour savoir ce qui a été touché.

> Version 1.5.0 · Licence Apache 2.0 · [Documentation technique](https://github.com/IronBranded/SCOPE25.Purview/blob/main/TECHNIQUE.md)

---

## Le problème

La plupart des organisations ne savent pas exactement quelles données personnelles elles détiennent, ni dans quels systèmes elles se trouvent.

En temps normal, c'est une lacune de gouvernance. Pendant un incident, ça devient urgent. Quand un site SharePoint ou une boîte aux lettres est compromis, la première question est : qu'est-ce qu'il y avait dedans? La réponse décide s'il y a un **risque de préjudice sérieux**, et donc s'il faut aviser la Commission d'accès à l'information et les personnes touchées.

L'outil ne répond pas à cette question à votre place. Il rassemble les faits dont une personne qualifiée aura besoin pour y répondre.

---

## Prérequis

Ce qu'il faut avant de commencer. Le détail, les options d'achat et les commandes d'installation sont dans [Préparer l'environnement](#préparer-lenvironnement).

- **PowerShell 5.1 minimum**, 7.4 ou plus récent recommandé. Testé sur 7.4.6.
- **Module `ExchangeOnlineManagement`** (3.0+) pour les deux étapes, **`Microsoft.Graph.Authentication`** (2.0+) pour l'étape 2. `Microsoft.Graph.Identity.Partner` seulement pour les MSSP.
- **Licence Microsoft 365 E3 ou Business Premium** pour l'étape 1 : installer les détecteurs, publier les étiquettes, produire le guide.
- **Licence E5, A5, G5 ou le module complémentaire Purview Suite pour l'étape 2.** L'inventaire passe par l'explorateur de contenu, réservé à ces licences. Sans ça, l'étape 1 fonctionne mais le graphique et la carte restent vides. **C'est le point le plus coûteux : réglez-le en premier.**
- **Rôle Compliance Administrator** pour l'étape 1 (écriture, une seule fois).
- **Pour l'étape 2, deux rôles qui ne s'additionnent pas :** un rôle d'accès (*Compliance Administrator*, *Compliance Data Administrator*, *Security Administrator* ou *Global Administrator*) **et en plus** le groupe *Content Explorer List Viewer*. N'attribuez pas *Content Explorer Content Viewer* : l'outil n'en a pas besoin.
- **Journalisation d'audit unifiée activée** dans le tenant. Plusieurs contrôles en dépendent.
- **Environ sept jours entre les deux étapes**, le temps que Purview indexe le contenu selon les nouveaux détecteurs.
- **Droit d'écriture** sur `%ProgramData%\Scope25.Purview` (journal) et le dossier Téléchargements (rapports).
- **Pour les MSSP :** relation GDAP active, appartenance au bon groupe de sécurité, et application autorisée dans le tenant du client.

Vérifiez la plupart de ces points d'un coup :

```powershell
Import-Module ./Scope25.Purview/Scope25.Purview.psd1
Test-Scope25Prerequisites | Format-Table -AutoSize -Wrap
```

---

## Comment ça marche : deux étapes, à quelques jours d'écart

Ce n'est pas un choix de commodité, c'est une contrainte technique. Microsoft n'applique pas un nouveau détecteur aux fichiers déjà là : tant qu'un document n'est pas modifié ou réindexé, le détecteur ne le voit pas. Si vous comptez le jour même du déploiement, vous obtenez des zéros qui ne veulent rien dire.

### Étape 1 — Déployer et guider

```powershell
Import-Module ./Scope25.Purview/Scope25.Purview.psd1
Connect-IPPSSession -UserPrincipalName admin@contoso.onmicrosoft.com

Invoke-Scope25Setup -WhatIf     # aperçu, ne change rien
Invoke-Scope25Setup
```

Installe les détecteurs québécois, publie les quatre étiquettes, note la date du déploiement et produit le **Guide Loi 25** : les 40 obligations avec leur base légale et les explications de la Commission. **Aucun chiffre de votre environnement à cette étape.**

Le guide sert dès le jour 1. Les obligations d'organisation — nommer un responsable, tenir des registres, faire des ÉFVP, revoir le consentement — forment la majeure partie du référentiel et n'attendent aucun délai technique.

### Entre les deux — vérifier que la classification est faite

Attendez **au moins sept jours**, puis allez voir dans le portail Purview :

| Quoi vérifier | Où |
|---|---|
| Les détecteurs sont là | *Classification des données › Types d'informations sensibles* — filtrez l'éditeur sur « Scope25.Purview » |
| Ils trouvent quelque chose | Ouvrez un détecteur Scope25 et regardez s'il y a des correspondances |
| Les quatre étiquettes existent | *Protection de l'information › Étiquettes de confidentialité* |
| Le contenu a été analysé | *Classification des données › Explorateur de contenu* — sommaire des fichiers non analysés |

Si un détecteur reste à zéro alors que vous savez que la donnée existe, c'est que le contenu n'a pas encore été réindexé. Forcer une réindexation se fait du côté SharePoint, en dehors de cet outil.

### Étape 2 — Auditer

```powershell
Connect-Scope25Tenant
Connect-IPPSSession -UserPrincipalName admin@contoso.onmicrosoft.com

Invoke-Scope25Audit
Invoke-Scope25Audit -IncludeEndpoints   # ajoute les noms de sites
```

L'outil relit la date de l'étape 1. Si le délai est trop court, il vous avertit et demande confirmation avant de produire un rapport trop tôt.

---

## Ce que contient le rapport

Un seul fichier HTML, en français, sans dépendance externe. Il s'ouvre hors ligne et s'imprime bien.

- **Un graphique circulaire par type détecté** : numéros d'assurance maladie, NAS, cartes de crédit, chèques spécimens, certificats d'état civil, adresses. Ces comptes ne dépendent pas de l'étiquetage — un détecteur trouve le contenu même si personne n'a déployé d'étiquettes.
- **Une carte des données** : quatre catégories (santé, identité, financier, adresse), les services où elles se trouvent, et ce que la Loi 25 demande pour chacune, avec l'article.
- **Les 40 obligations**, chacune avec ce qui a été observé, ou la note qu'aucun signal technique ne permet de la vérifier.

---

## Trois choses à savoir avant de l'utiliser

**1. L'outil ne dit jamais si vous êtes conforme.** Aucun contrôle n'affiche « conforme » ou « non conforme ». Presque toutes les obligations de la Loi 25 demandent un jugement qu'un logiciel ne peut pas faire : est-ce que cette durée de conservation convient à la finalité? Est-ce que le consentement était valide? Est-ce que cet incident présente un risque de préjudice sérieux? Un outil qui afficherait « conforme » à côté de ces questions affirmerait quelque chose qu'il n'a aucun moyen de savoir. Chaque contrôle a plutôt une case et un champ de notes pour la personne qui révise.

Sur 40 obligations, **16 laissent une trace technique. Les 24 autres passent par des gens et des documents.**

**2. Un zéro veut dire « rien de vu », jamais « rien là ».** Si vous lisez « 0 numéro d'assurance maladie » pour un site compromis et que vous en concluez qu'aucune donnée de santé n'a été exposée, alors que rien n'y a été analysé, vous risquez de ne pas aviser la Commission quand il le faudrait. L'inventaire se prépare quand tout va bien.

**3. Le rapport est lui-même sensible.** Il peut nommer les endroits où se concentrent les données les plus recherchées. Après un incident, rien ne dit que l'attaquant est parti. Le rapport affiche un avis de confidentialité quand ces détails sont inclus. Les boîtes aux lettres nominatives ne sont jamais listées : une liste d'employés nommés avec des données de santé serait elle-même un document de renseignements personnels.

---

## Qui doit valider les résultats

| Rôle | Ce qu'il tranche |
|---|---|
| **Spécialiste Purview ou conformité** | Si l'interprétation technique est bonne, et ce que l'outil n'a pas vu |
| **Responsable de la réponse aux incidents** | L'étendue réelle d'un incident et si le processus tient sous pression |
| **Breach coach** | Le seuil de « préjudice sérieux » et la décision d'aviser la Commission |
| **Équipe juridique** | Toute conclusion de conformité et ce qui est remis à un tiers |

---

## Vérifier les détecteurs avant de les déployer

```powershell
Test-Scope25SitPattern -Detailed
```

Passe chaque expression de détection dans 24 cas de test, hors ligne, sans tenant et sans donnée réelle. Les cas **négatifs** comptent autant que les positifs : un code postal de Toronto, un mois de naissance impossible, un code de banque qui n'existe pas. Un détecteur qui attrape tout n'attrape rien d'utile.

Les expressions sont lues directement dans le fichier de règles, pas recopiées. Si quelqu'un modifie un détecteur sans ajuster les tests, le jeu de tests le dit. Il détecte aussi le cas inverse : un détecteur ajouté sans test.

Ces tests valident la **logique** des expressions, pas le moteur de Purview. Un détecteur qui passe ici reste à confirmer dans un vrai tenant avec `Test-DataClassification`.

---

## Préparer l'environnement

Le détail des prérequis listés plus haut : ce que couvre chaque licence, comment obtenir E5 temporairement, et les commandes d'installation.

### Ce que couvre chaque licence

| Fonction | Licence minimale |
|---|---|
| **Guide Loi 25 (étape 1)** | Aucune |
| Import des détecteurs | Microsoft 365 E3 ou Business Premium |
| Étiquettes appliquées à la main | E3 ou Business Premium |
| **Inventaire de l'étape 2 : graphique circulaire, carte, comptes** | **E5 / A5 / G5, ou le module de conformité E5 (Purview Suite)** |
| Étiquetage automatique | E5, ou Information Protection Plan 2 |
| Journaux d'audit gardés plus longtemps | E5 ou module Audit Premium |

Tout l'inventaire de l'étape 2 passe par l'**explorateur de contenu**, que Microsoft réserve à E5 et l'équivalent. Sans E5, l'étape 1 fonctionne normalement, mais le graphique circulaire et la carte restent vides.

### Obtenir E5 temporairement, et à qui il faut l'attribuer

**Est-ce qu'une seule licence sur le compte admin suffit pour analyser tout le tenant?** Techniquement oui, l'explorateur de contenu montre tout le tenant. Côté contrat, c'est loin d'être clair, et la réponse prudente est non.

Microsoft demande de licencier toute personne qui **bénéficie du service, directement ou indirectement**. Leur propre exemple ressemble beaucoup au nôtre : quand un admin applique une politique de rétention à tous les fichiers SharePoint, chaque utilisateur SharePoint en bénéficie et doit avoir une licence.

Il y a aussi une clause contre le *multiplexage* : utiliser un logiciel pour accéder à l'information de façon indirecte et réduire le nombre d'utilisateurs comptés **ne réduit pas le nombre de licences**. Scope25.Purview fait exactement ça — un logiciel qui interroge Purview pour le compte d'un admin et rend compte des données de tout le monde. Microsoft précise aussi que la licence est requise même quand rien ne bloque techniquement.

Autre signe : pour eDiscovery (Premium), Microsoft écrit clairement que les admins et enquêteurs qui utilisent l'outil n'ont pas besoin de licence, mais que les dépositaires en ont besoin. Microsoft sait donc écrire une exception pour les admins quand il en veut une. Il n'y en a pas pour l'explorateur de contenu.

La question est ouverte publiquement. Un fil de la communauté Microsoft d'avril 2026 pose exactement le même problème : il faut l'explorateur de contenu pour savoir qui manipule des données sensibles, et il faut le savoir pour décider combien de licences acheter. **Faites confirmer votre cas par écrit avec votre revendeur ou Microsoft. Ce qui suit vient des conditions publiées par Microsoft. Ce n'est pas un avis contractuel.**

| Option | Coût | Quand l'utiliser |
|---|---|---|
| **1. Essai Purview Suite, 90 jours** | **Gratuit** | Le meilleur choix pour un audit ponctuel. Ajoute 25 licences Purview Suite automatiquement. Il faut avoir Microsoft 365 E3, ou Office 365 E3 + EMS E3, et **pas déjà** E5. Pas offert aux tenants gouvernementaux. Un seul essai par tenant. |
| **2. Module complémentaire Purview Suite au mois** | Par utilisateur analysé | Si l'essai a déjà été utilisé ou que le tenant n'est pas admissible. Achetez au mois par un partenaire, puis annulez après l'audit. |
| **3. Limiter la portée avec des unités administratives** | Par utilisateur analysé, mais moins de monde | L'explorateur de contenu accepte les unités administratives. Licenciez un groupe précis et n'analysez que lui. C'est le seul moyen défendable de réduire le nombre de licences. |

Pour démarrer l'essai : portail Purview, section *Essais et recommandations*. Il faut le rôle Administrateur de facturation, de conformité, des données de conformité, ou Administrateur général. L'essai démarre tout de suite, mais comptez jusqu'à deux heures avant que tout apparaisse.

**Trois pièges de l'essai :**

- Il peut se convertir en abonnement payant à la fin, et les 25 licences peuvent basculer même si vous en avez utilisé moins. Notez la date de fin et annulez avant.
- Ce qui a été créé pendant l'essai peut rester après : étiquettes, politiques, contenu étiqueté. Prévoyez le nettoyage.
- 25 licences ne couvrent pas un tenant plus gros. Analyser 500 boîtes aux lettres avec un essai de 25 licences soulève la même question de multiplexage. Au-delà de 25 personnes, combinez avec l'option 3.

**Attention à l'admissibilité :** Business Premium n'est pas dans les critères publiés (E3, ou O365 E3 + EMS E3). Beaucoup de PME québécoises sont sur Business Premium. Vérifiez avant de promettre un audit complet à un client.

**Ordre à suivre :** l'essai dure 90 jours et l'indexation prend au moins sept jours.

1. Faites l'étape 1 **avant** de démarrer l'essai — elle ne demande que E3.
2. Démarrez l'essai une fois les détecteurs installés, pas avant. Sinon vous perdez des jours à attendre l'indexation.
3. Laissez indexer, puis vérifiez la couverture.
4. Faites l'étape 2 bien avant la fin, pour pouvoir reprendre si la couverture était incomplète.
5. Annulez l'essai.

### PowerShell

- **5.1 minimum, 7.4 ou plus récent recommandé.** L'outil est développé et testé sur 7.4.6.
- Stratégie d'exécution `RemoteSigned` ou moins stricte : `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`
- Si le dossier vient d'Internet : `Get-ChildItem -Recurse | Unblock-File` avant de l'importer.
- Sur Windows PowerShell 5.1 seulement, activez TLS 1.2 : `[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12`

### Modules PowerShell

```powershell
Install-Module ExchangeOnlineManagement         -Scope CurrentUser   # étapes 1 et 2
Install-Module Microsoft.Graph.Authentication   -Scope CurrentUser   # étape 2
Install-Module Microsoft.Graph.Identity.Partner -Scope CurrentUser   # MSSP seulement
```

Aucun n'est déclaré dans `RequiredModules`. Le module s'importe sans eux, et chaque commande vous dit quoi installer au moment voulu. Vous pouvez donc lire le guide et tester les détecteurs sans rien installer.

### Rôles

| Usage | Rôle |
|---|---|
| Étape 1, déploiement | **Compliance Administrator** (écriture, une seule fois) |
| Étape 2, inventaire | Un rôle d'accès — *Compliance Administrator*, *Compliance Data Administrator*, *Security Administrator* ou *Global Administrator* — **et en plus** le groupe **Content Explorer List Viewer** |
| Étape 2, lecture Graph | **Global Reader**, *Security Reader* ou *Reports Reader* |
| Découverte GDAP (MSSP) | `DelegatedAdminRelationship.Read.All` |

Deux détails qui font perdre du temps :

- **Les deux groupes de l'étape 2 ne s'additionnent pas.** Un rôle d'accès tout seul donne l'onglet mais aucun élément. *Content Explorer List Viewer* tout seul ne suffit pas non plus. Il faut les deux.
- **N'attribuez pas *Content Explorer Content Viewer*.** Il donne accès au contenu des fichiers analysés. L'outil ne demande que des totaux et n'en a pas besoin. C'est un privilège de trop sur des données personnelles.

Portées Graph demandées par `Connect-Scope25Tenant` : `AuditLogsQuery-Entra.Read.All`, `AuditLog.Read.All`, `Directory.Read.All`, `Reports.Read.All`. Jamais la portée globale `AuditLogsQuery.Read.All`.

### Côté tenant et poste de travail

Les points d'écriture, la journalisation d'audit et les exigences GDAP sont dans la liste plus haut. Deux précisions qui s'y ajoutent :

- Une erreur `AADSTS90099` à la connexion veut dire exactement une chose : l'application n'a pas encore été autorisée dans le tenant du client. C'est un consentement unique à donner une fois.
- Le rapport s'ouvre dans n'importe quel navigateur récent, sans connexion Internet.

Plus de détails dans la [documentation technique](https://github.com/IronBranded/SCOPE25.Purview/blob/main/TECHNIQUE.md).

---

## État du projet et limites

Le module a été **exécuté et testé sur PowerShell 7.4.6**. La suite `tests/Test-Scope25.ps1` couvre les diagnostics, le contrôle préalable, le journal et sa chaîne d'empreintes (y compris la détection d'une modification), la production du guide **et du rapport d'audit complet**, les 24 cas de test des détecteurs, et les messages d'erreur des commandes qui demandent une session. Tout passe.

Le test du rapport d'audit a été ajouté après coup, parce que ce chemin n'avait jamais été exécuté et contenait un bogue : une clé JSON accentuée par erreur vidait silencieusement toute la cartographie du rapport. Le test vérifie maintenant que chaque clé de la charge utile reste en ASCII.

**Ce qui n'a pas été testé :** tout ce qui interroge un vrai tenant Microsoft 365. Les noms de commandes et leurs paramètres viennent de la documentation de Microsoft, mais n'ont jamais été exécutés pour vrai. Traitez le premier essai chez un client comme une mise au point.

Autres limites :

- **Microsoft 365 seulement.** Pas les serveurs sur place, pas les applications tierces, pas le papier.
- **Seulement des détecteurs à format publié.** Ceux du permis d'armes à feu et des permis de chasse et pêche ont été **retirés**, pas juste rétrogradés : aucun format officiel n'existe, ils se seraient déclenchés surtout par hasard. Dans un rapport qui prétend rapporter ce qu'il voit, un détecteur bruyant décrédibilise les bons. Pour ces numéros-là, l'Exact Data Match sur la vraie liste du client est le bon outil.
- **La chaîne d'empreintes rend une modification visible, pas impossible.** Pour une preuve qui doit tenir devant un adversaire, envoyez les entrées vers un stockage inaltérable ou un SIEM.
- **Aucun binaire compilé.** Tout est en PowerShell, JSON et XML lisibles. Un outil d'audit qui demanderait de faire confiance à un binaire fermé demanderait quelque chose qu'il n'a pas mérité.

---

## Licence et contributions

**Apache 2.0.** Usage commercial permis sans restriction, y compris pour un fournisseur qui facture des mandats bâtis sur cet outil. Apache plutôt que MIT pour deux raisons : une licence de brevet explicite, et l'obligation d'indiquer les fichiers modifiés. Ça compte pour un outil d'audit, où savoir si les règles de détection ont été changées fait partie de la preuve.

Voir [CONTRIBUTING.md](https://github.com/IronBranded/SCOPE25.Purview/blob/main/CONTRIBUTING.md) pour les règles, notamment celle qui compte le plus : un détecteur nest accepté que sil repose sur un format publié et vérifiable. Pour signaler une faille, voir [SECURITY.md](https://github.com/IronBranded/SCOPE25.Purview/blob/main/SECURITY.md).

Contributions les plus utiles : tester les détecteurs sur des données réelles, et couvrir les obligations du secteur public (chapitre A-2.1).

---

## English summary

Scope25.Purview is an open-source PowerShell module that inventories personal data in Microsoft 365 and maps it to Quebec's Law 25 obligations. It runs in two stages: `Invoke-Scope25Setup` deploys Quebec-specific detectors and produces a guide containing no tenant data, then `Invoke-Scope25Audit` produces the full report once Purview has had time to index — typically a week later, because Microsoft does not retroactively classify existing files against a newly added detector.

**The tool renders no compliance verdicts.** Most Law 25 obligations turn on judgement software cannot make, so it reports findings and leaves conclusions to a Purview specialist, an incident response commander, a breach coach, and legal counsel. A zero means "not observed", never "not present."

Step 2 requires Microsoft 365 E5 or the E5 Compliance add-on, because it depends on Content Explorer. Step 1 does not. Note that Microsoft's licensing terms require licensing every user who benefits from a service, and their anti-multiplexing clause covers tools that query on an admin's behalf — a single admin licence is unlikely to be defensible. See the prerequisites section.

Reports and user-facing content are in French, since the tool targets Quebec organisations. Code and comments are in English. Apache 2.0 licensed; commercial use permitted.

---

*Scope25.Purview n'est ni développé ni approuvé par Microsoft. Microsoft, Microsoft 365, Microsoft Purview et Microsoft Entra sont des marques de commerce de Microsoft Corporation.*
