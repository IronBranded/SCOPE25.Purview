# Contribuer

## Avant tout : jamais de vraies données

Les fichiers de test ne doivent contenir que des valeurs fictives construites pour respecter la forme d'un identifiant. Ce dépôt est public. Un vrai numéro d'assurance maladie dans un cas de test est une fuite de renseignements personnels.

La RAMQ publie une liste officielle de numéros fictifs pour la formation — c'est le bon matériel.

## Ajouter un détecteur

Un détecteur n'est accepté que s'il repose sur un **format publié et vérifiable**. C'est la règle qui a mené au retrait des détecteurs de permis d'armes à feu et de permis de chasse et pêche : aucun format officiel n'existe pour eux, ils se déclenchaient surtout par hasard, et un détecteur bruyant décrédibilise les bons.

Si l'identifiant n'a pas de format publié, l'outil approprié est l'Exact Data Match sur la liste réelle du client, pas une expression régulière.

Pour ajouter un détecteur :

1. Ajoutez l'entité dans `Templates/Quebec_SITs.xml`, avec un commentaire indiquant **la source du format**.
2. Ajoutez des cas de test dans `Templates/Scope25_SitTests.json` — **des positifs et des négatifs**. Les négatifs mesurent la précision; sans eux, un détecteur qui attrape tout passe le test.
3. Lancez `Test-Scope25SitPattern -Detailed`. Le banc signale aussi les détecteurs sans test et les tests orphelins.
4. Ajoutez le détecteur au catalogue de `Get-Scope25SitDetection` et à la catégorie voulue dans `Scope25_Labels.json`.

## Ajouter un contrôle Loi 25

Dans `Templates/Loi25_Template.json`. Chaque contrôle doit porter :

- une citation d'article **vérifiée dans le texte officiel** (P-39.1 sur LégisQuébec), pas dans une page de vulgarisation. Une version antérieure du référentiel affirmait à tort que l'anonymisation était interdite parce qu'elle s'appuyait sur une page de la Commission restée périmée par rapport au règlement.
- un `tier` : `automated-high-confidence`, `automated-flagged-for-review` ou `attestation`.
- le champ `sapExposure` si l'article 90.1 rattache le manquement à une sanction pécuniaire.

Si vous ne trouvez pas l'article, écrivez-le : mieux vaut une citation marquée « non vérifiée » qu'une citation inventée.

## Langue

Tout ce que voit un utilisateur — rapport, guide, messages, README — est en **français**. Le code et les commentaires sont en **anglais**, convention PowerShell.

Attention aux passes de correction globale : deux bogues de ce dépôt viennent de remplacements qui ont traversé la frontière entre le texte et le code. Une passe d'accents avait produit « vérifiéd » dans de l'aide anglaise, et une autre avait accentué une clé JSON, ce qui vidait silencieusement une section entière du rapport.

## Tests

```powershell
pwsh -NoProfile -File tests/Test-Scope25.ps1
```

Toute contribution doit laisser la suite verte. Si vous corrigez un bogue, ajoutez d'abord le test qui échoue — puis vérifiez qu'il échoue vraiment avant de corriger. Un test qu'on n'a jamais vu échouer ne prouve rien.
