<#
    Test-Scope25.ps1 - tests fonctionnels hors tenant.

    Couvre tout ce qui ne demande ni Microsoft Graph ni Security & Compliance PowerShell :
    diagnostics, journal et chaine d'empreintes (y compris la detection d'une falsification),
    generation du guide de l'etape 1, et les garde-fous des cmdlets qui exigent une session.

    Ces tests ont ete executes sous PowerShell 7.4.6 et passent tous. Ils ne couvrent PAS les
    chemins qui interrogent un tenant reel - ceux-la restent a valider par qui dispose d'un
    environnement Microsoft 365.

    Usage :  pwsh -NoProfile -File tests/Test-Scope25.ps1
#>

Import-Module (Join-Path $PSScriptRoot ".." "Scope25.Purview.psd1") -Force
$script:fail = 0
function Check($n,$ok,$d){ if($ok){Write-Host "  PASS  $n -> $d" -ForegroundColor Green} else {Write-Host "  FAIL  $n -> $d" -ForegroundColor Red; $script:fail++} }

Write-Host "=== Diagnostics ===" -ForegroundColor Cyan
$i = Get-Scope25ModuleInfo
# Comparer au manifeste plutot qu'a une version en dur : une assertion codee en dur
# echoue a chaque increment de version sans rien reveler d'utile.
$manifestVersion = (Import-PowerShellDataFile (Join-Path $PSScriptRoot ".." "Scope25.Purview.psd1")).ModuleVersion
Check "Get-Scope25ModuleInfo" ($i.ModuleVersion -eq $manifestVersion) "v$($i.ModuleVersion) concorde avec le manifeste"
$pre = @(Test-Scope25Prerequisites)
Check "Test-Scope25Prerequisites retourne des verifications" ($pre.Count -ge 10) "$($pre.Count) verifications"
$cats = @($pre.Categorie | Select-Object -Unique)
Check "Categories attendues presentes" (($cats -contains 'Execution' -or $cats -contains "Ex$([char]0xE9)cution") -and $cats -contains 'Modules' -and $cats -contains 'Sessions') `
      "$($cats -join ', ')"
$ver = $pre | Where-Object { $_.Element -like '*PowerShell*' } | Select-Object -First 1
Check "Version de PowerShell evaluee" ($ver.Etat -eq 'OK') "$($ver.Detail)"
$manuel = @($pre | Where-Object { $_.Etat -eq 'MANUEL' })
Check "Les limites du controle sont nommees" ($manuel.Count -ge 3) "$($manuel.Count) elements a confirmer a la main (licence, roles, journalisation)"

Write-Host ""
Write-Host "=== Journal + chaine d'empreintes ===" -ForegroundColor Cyan
# Partir d'un journal vide : sinon une entree laissee par une execution precedente
# occupe l'index 0 et le test de falsification devient dependant de l'ordre.
$logDir = if ($env:ProgramData) { Join-Path $env:ProgramData 'Scope25.Purview/Logs' } else { Join-Path $HOME '.scope25-purview/logs' }
$logFile = Join-Path $logDir 'scope25-operations.log'
if (Test-Path $logFile) { Remove-Item $logFile -Force }

$e1 = Write-Scope25AuditLog -Action "Test-A" -Outcome "Success" -Detail "premiere entree"
$e2 = Write-Scope25AuditLog -Action "Test-B" -Outcome "Success" -Detail "deuxieme entree"
Check "Write-Scope25AuditLog" ($e1.Action -eq "Test-A" -and $e2.PreviousHash -ne ("0"*64)) "chainage OK"
$g = Test-Scope25LogIntegrity
Check "Chaine intacte" ($g.ChainIntact -eq $true) "$($g.EntryCount) entrees"

$lp = $g.LogPath
$lines = @(Get-Content $lp)
$idx = 0..($lines.Count-1) | Where-Object { $lines[$_] -like '*premiere entree*' } | Select-Object -First 1
Check "Ligne cible reperee" ($null -ne $idx) "index $idx"
$lines[$idx] = $lines[$idx].Replace("premiere entree","ALTEREE")
Set-Content -Path $lp -Value $lines
$t = Test-Scope25LogIntegrity
Check "Falsification detectee" ($t.ChainIntact -eq $false) "rupture ligne(s) $($t.BrokenAtLine -join ',')"
if (Test-Path $lp) { Remove-Item $lp -Force }

Write-Host ""
Write-Host "=== Etape 1 : guide, sans tenant ===" -ForegroundColor Cyan
$a = @(Invoke-Scope25Loi25Assessment -GuideOnly -SkipAuditLog)
Check "Assessment -GuideOnly" ($a.Count -eq 40) "$($a.Count) controles; statuts: $(($a.Status | Select-Object -Unique) -join ',')"
$s = $a | Get-Scope25AssessmentSummary
Check "Summary" ($s.TotalControls -eq 40) "technique=$($s.TechnicalSignalControls) humain=$($s.HumanEvidenceControls)"
Check "Aucun score" (-not ($s.PSObject.Properties.Name -contains 'AutomatedScorePercent')) "aucune propriete de score"

$out = "/tmp/psreport"; New-Item -Path $out -ItemType Directory -Force | Out-Null
$path = $a | New-Scope25Report -Mode Guide -TenantLabel "test.onmicrosoft.com" -OutputDirectory $out -PassThru
Check "New-Scope25Report -Mode Guide" (Test-Path $path) "$([IO.Path]::GetFileName($path))"
$html = Get-Content $path -Raw
Check "Placeholder consomme" (-not $html.Contains('__SCOPE25_DATA__')) "injection faite"
Check "Mode Guide dans la charge utile" ($html -match '"mode":\s*"Guide"') "mode=Guide"
Check "Nom de fichier Guide" ([IO.Path]::GetFileName($path) -like 'Scope25-Guide-*') "prefixe correct"

Write-Host ""
Write-Host "=== Etape 2 : rapport d'audit complet ===" -ForegroundColor Cyan
# Ce chemin n'avait jamais ete execute et contenait une cle JSON corrompue
# (categories -> categories accentue), ce qui vidait silencieusement toute la
# cartographie du rapport. Il est teste ici pour que ca ne se reproduise pas.
$labDef = Get-Content (Join-Path $PSScriptRoot ".." "Templates" "Scope25_Labels.json") -Raw | ConvertFrom-Json
$sitsFactices = @(
  [pscustomobject]@{ SitName='Credit Card Number'; Category='Financier'; Source='Microsoft'; ItemCount=1042; Confidence='Tous niveaux'; State='Recueillie' }
  [pscustomobject]@{ SitName='Quebec RAMQ Health Insurance Number (NAM)'; Category='Sante'; Source='Scope25'; ItemCount=408; Confidence='Tous niveaux'; State='Recueillie' }
  [pscustomobject]@{ SitName='Detecteur a zero'; Category='Adresse'; Source='Scope25'; ItemCount=0; Confidence='Tous niveaux'; State='Recueillie' }
)
$mapFactice = foreach ($L in $labDef.labels) {
  [pscustomobject]@{
    Category=$L.name; DisplayFr=$L.displayNameFr; DataTypesFr=@($L.dataTypesFr); TotalItems=100
    ByWorkload=@([pscustomobject]@{ Workload='SharePoint'; ItemCount=100 })
    Endpoints=@(); EndpointDetail=$false
    Classification=$L.caiGuidance.classificationFr
    CaiObligations=@($L.caiGuidance.obligationsFr); CaiAction=$L.caiGuidance.actionFr
    ConfidenceNote=$L.confidenceNote
  }
}
$auditPath = $a | New-Scope25Report -Mode Audit -DataMap $mapFactice -SitDetection $sitsFactices `
                -SitsImportedOn (Get-Date).AddDays(-14) -TenantLabel 'test.onmicrosoft.com' `
                -OutputDirectory $out -PassThru
Check "New-Scope25Report -Mode Audit" (Test-Path $auditPath) "$([IO.Path]::GetFileName($auditPath))"
$ah = Get-Content $auditPath -Raw
Check "Nom de fichier Audit" ([IO.Path]::GetFileName($auditPath) -like 'Scope25-Audit-*') "prefixe correct"

# Extraire et reparser la charge utile : c'est la seule facon de voir une cle cassee
if ($ah -match 'var SCOPE25 = (\{.*?\});\r?\n') {
    $payload = $Matches[1] | ConvertFrom-Json
    Check "Charge utile reparsable" ($null -ne $payload) "JSON valide"
    Check "Mode Audit dans la charge utile" ($payload.mode -eq 'Audit') "mode=$($payload.mode)"
    $dmKeys = @($payload.dataMap.PSObject.Properties.Name)
    Check "Cle 'categories' presente et non accentuee" ($dmKeys -contains 'categories') "cles: $($dmKeys -join ', ')"
    Check "Cartographie peuplee" (@($payload.dataMap.categories).Count -eq 4) "$(@($payload.dataMap.categories).Count) categories"
    Check "Detecteurs a zero exclus" (@($payload.sits).Count -eq 2) "$(@($payload.sits).Count) sur 3 fournis"
    Check "Tri decroissant des detections" ($payload.sits[0].itemCount -ge $payload.sits[-1].itemCount) "$($payload.sits[0].itemCount) en tete"
    Check "Anciennete de l'indexation transmise" ($payload.freshness.daysSinceImport -eq 14) "$($payload.freshness.daysSinceImport) jours"
    Check "Obligations CAI par categorie" (@($payload.dataMap.categories[0].caiObligations).Count -gt 0) "$(@($payload.dataMap.categories[0].caiObligations).Count) obligations"
    Check "Toutes les cles de charge utile en ASCII" (-not ($Matches[1] -match '"[^"]*[\u00C0-\u017F][^"]*"\s*:')) "aucune cle accentuee"
} else {
    Check "Charge utile reparsable" $false "bloc SCOPE25 introuvable dans le rapport"
}

Write-Host ""
Write-Host "=== Motifs de detection (hors ligne) ===" -ForegroundColor Cyan
$pat = @(Test-Scope25SitPattern)
# Sans ce garde-fou, les deux verifications suivantes passent sur un tableau vide -
# elles resteraient vertes si la cmdlet disparaissait.
Check "Le banc d'essai retourne des resultats" ($pat.Count -gt 0) "$($pat.Count) motif(s) evalue(s)"
Check "Tous les motifs couverts par des tests" (@($pat | Where-Object { $_.Statut -eq 'SANS TEST' }).Count -eq 0) `
      "$(@($pat | Where-Object { $_.Statut -eq 'SANS TEST' }).RegexId -join ', ')"
Check "Aucun vecteur orphelin" (@($pat | Where-Object { $_.Statut -eq 'MOTIF ABSENT' }).Count -eq 0) `
      "aucun vecteur ne pointe vers un motif supprime"
foreach ($m in ($pat | Where-Object { $_.Statut -in 'OK','ECHEC','ÉCHEC' })) {
    Check "Motif : $($m.Motif)" ($m.Echecs -eq 0) "$($m.Reussis) cas; $($m.Detail)"
}
$totalCas = ($pat | Measure-Object -Property Reussis -Sum).Sum
Check "Couverture des motifs" ($totalCas -ge 20) "$totalCas cas de test executes"

Write-Host ""
Write-Host "=== Degradation sans session ===" -ForegroundColor Cyan
# Le module s'importe volontairement sans Microsoft.Graph ni ExchangeOnlineManagement.
# Ces chemins doivent degrader proprement, pas lever une CommandNotFoundException brute.
$full = @(Invoke-Scope25Loi25Assessment -SkipAuditLog -WarningAction SilentlyContinue)
Check "Evaluation complete sans session" ($full.Count -eq 40) "$($full.Count) controles"
$tech = @($full | Where-Object { $_.Tier -ne 'attestation' -and $_.ControlId -ne 'GOV-06' })
Check "Constats techniques marques Indisponible" (@($tech | Where-Object { $_.Status -ne 'Indisponible' }).Count -eq 0) `
      "$($tech.Count) controles, aucun faux constat"
Check "Constats en francais" (-not ($full.Evidence -join ' ' -match 'No (Security|Graph) ')) "aucun message anglais dans les constats"

try { $ci = Get-Scope25ConnectionInfo -WarningAction SilentlyContinue
      Check "Get-Scope25ConnectionInfo sans Graph" ($null -eq $ci) "retourne null au lieu de planter" }
catch { Check "Get-Scope25ConnectionInfo sans Graph" $false "a leve : $($_.Exception.Message)" }

try { Disconnect-Scope25Tenant -ErrorAction Stop
      Check "Disconnect-Scope25Tenant sans Graph" $true "ne plante pas" }
catch { Check "Disconnect-Scope25Tenant sans Graph" $false "a leve : $($_.Exception.Message)" }

$setupOut = Join-Path $out "setup"
New-Item $setupOut -ItemType Directory -Force | Out-Null
try {
  $sr = Invoke-Scope25Setup -SkipDeployment -OutputDirectory $setupOut -TenantLabel 'test.local' -Confirm:$false -WarningAction SilentlyContinue
  Check "Invoke-Scope25Setup -SkipDeployment" (Test-Path $sr.GuidePath) "guide produit sans toucher au tenant"
  Check "Etat de deploiement enregistre" (Test-Path $sr.StatePath) "$([IO.Path]::GetFileName($sr.StatePath))"
} catch { Check "Invoke-Scope25Setup -SkipDeployment" $false $_.Exception.Message }

Write-Host ""
Write-Host "=== Garde-fous : cmdlets qui exigent une session ===" -ForegroundColor Cyan
try { Get-Scope25SitDetection -ErrorAction Stop; Check "Get-Scope25SitDetection sans session" $false "aurait du lever une erreur" }
catch { Check "Get-Scope25SitDetection sans session" ($_.Exception.Message -like '*Connect-IPPSSession*') "message actionnable" }
try { Import-Scope25QuebecSIT -WhatIf -ErrorAction Stop; Check "Import-Scope25QuebecSIT sans session" $false "aurait du lever une erreur" }
catch { Check "Import-Scope25QuebecSIT sans session" ($_.Exception.Message -like '*Connect-IPPSSession*') "message actionnable" }
try { Get-Scope25LabelCoverage -ErrorAction Stop; Check "Get-Scope25LabelCoverage sans session" $false "aurait du lever une erreur" }
catch { Check "Get-Scope25LabelCoverage sans session" ($_.Exception.Message -like '*Connect*') "message actionnable" }

Write-Host ""
if ($script:fail -eq 0) { Write-Host "TOUS LES TESTS FONCTIONNELS PASSENT" -ForegroundColor Green }
else { Write-Host "$($script:fail) TEST(S) EN ECHEC" -ForegroundColor Red }

exit $script:fail
