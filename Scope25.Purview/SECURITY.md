# Politique de sécurité

## Signaler une vulnérabilité

N'ouvrez pas d'issue publique pour une faille de sécurité. Écrivez plutôt à `[COURRIEL DE SÉCURITÉ À DÉFINIR]`.

Ce qui aide dans un signalement : la version du module, ce qui se produit, et comment le reproduire.

## Ce qui compte comme vulnérabilité ici

Cet outil lit des renseignements personnels et produit des documents qui décrivent où ils se trouvent. Sont donc considérés comme des failles :

- Une commande qui expose plus de données que ce que son rôle documenté permet — par exemple qui retournerait du contenu de fichier alors que seul un total est attendu.
- Un rapport qui contiendrait des données personnelles non prévues, notamment des noms de boîtes aux lettres. L'outil ne doit **jamais** énumérer de boîtes nominatives.
- Une écriture du journal ou du rapport à un emplacement moins protégé que prévu.
- Une commande d'écriture qui modifierait le tenant sans passer par `ShouldProcess` (`-WhatIf` / `-Confirm`).
- Un détecteur qui produirait des faux négatifs systématiques, puisqu'un constat manquant peut mener à ne pas déclarer un incident à la Commission d'accès à l'information.

## Ce qui n'en est pas

- **Un zéro dans un rapport n'est pas une faille.** Purview ne reclasse pas rétroactivement le contenu existant : un détecteur récemment installé ne voit pas les fichiers non réindexés. Le rapport le dit explicitement. Voir le README.
- **La chaîne d'empreintes du journal rend une modification visible, pas impossible.** C'est documenté comme tel. Pour une preuve devant résister à un adversaire, il faut expédier les entrées vers un stockage inaltérable.
- **L'absence de détecteur pour un identifiant sans format publié** est une décision assumée, pas un oubli. Voir la section sur les détecteurs retirés.

## Portée

Le module s'exécute localement et n'envoie aucune donnée à un tiers. Les rapports et journaux restent sur vos systèmes.
