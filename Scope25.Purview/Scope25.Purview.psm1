#Requires -Version 5.1
<#
    Scope25.Purview.psm1
    ---------------------------------------------------------------------
    Public function layer for the Scope25.Purview module.

    Language note: code, comments, and cmdlet help are kept in English
    (standard PowerShell convention, and this travels to MSSP technicians
    who may not all read French). Content actually shown to a client's
    end users - README.md, the sensitivity labels, the generated HTML
    report, the EULA - is French-first for the Quebec market. Flag it if
    you'd rather have bilingual or French-only code comments; easy to
    change now, painful once the module grows.

    Ce que fait ce module, en bref :
      Connexion            - Connect-Scope25Tenant (delegue, compatible GDAP, portees minimales)
      Detection            - Import-Scope25QuebecSIT, Publish-Scope25SensitivityLabels
      Inventaire           - Get-Scope25DataMap, Get-Scope25SitDetection, Get-Scope25LabelCoverage
      Referentiel Loi 25   - Invoke-Scope25Loi25Assessment (recueille des preuves, ne juge pas)
      Rapport              - New-Scope25Report
      Tracabilite          - Write-Scope25AuditLog, Test-Scope25LogIntegrity

    Phase 2 note: Connect-Scope25Tenant uses DELEGATED (interactive,
    signed-in-user) authentication via Connect-MgGraph. That's the
    well-documented, Microsoft-recommended way to use GDAP today. It is
    NOT the same thing as unattended/scheduled automation - true app-only
    access across many GDAP customer tenants remains a genuinely
    unresolved friction point in the Microsoft ecosystem as of this
    writing (the old DAP-era "Secure Application Model" does not carry
    over cleanly to GDAP). Don't oversell "GDAP support" internally as
    "fully unattended MSSP automation" - it isn't yet, for anyone,
    Scope25 included. See Connect-Scope25Tenant's help for the AADSTS90099
    gotcha, which real partners hit constantly and which has a simple,
    one-time fix once you know what it is.

    Phase 4 note: Import-Scope25QuebecSIT and Publish-Scope25SensitivityLabels
    are WRITE operations against the connected tenant; Get-Scope25LabelCoverage
    reads Content Explorer data. All three still expect an active Security
    & Compliance PowerShell session (Connect-IPPSSession, from the
    ExchangeOnlineManagement module) - that's a DIFFERENT connection from
    the Microsoft Graph one Connect-Scope25Tenant establishes, because
    Security & Compliance PowerShell and Microsoft Graph are two separate
    Microsoft services with separate sign-in flows. Nothing in this
    module has been run against a real tenant: there is no PowerShell/
    Graph/Purview connectivity in the environment that generated it.
    Start with -WhatIf on every write cmdlet.
    ---------------------------------------------------------------------
#>

Set-StrictMode -Version Latest

$Script:Scope25ModuleRoot = $PSScriptRoot

# No compiled binary ships with this module. Everything is readable PowerShell, JSON and
# XML, deliberately: a forensic tool that asks you to trust an opaque DLL is asking for
# something it has not earned. Every detection rule and every check can be read, audited
# and modified by whoever runs it.

$Script:Scope25Version    = (Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot 'Scope25.Purview.psd1')).ModuleVersion

# Deliberately narrow, workload-scoped defaults rather than one broad grant.
# AuditLogsQuery-Entra.Read.All is the least-privileged permission for the
# Purview Audit Search Graph API (Entra workload only); add the -Exchange /
# -SharePoint / -OneDrive variants via -Scopes on Connect-Scope25Tenant once
# a Phase 3 control actually needs that workload's audit data - don't
# request them by default just in case.
$Script:Scope25DefaultGraphScopes = @(
    'AuditLogsQuery-Entra.Read.All',
    'AuditLog.Read.All',
    'Directory.Read.All',
    'Reports.Read.All'
)

function Get-Scope25ModuleInfo {
    <#
    .SYNOPSIS
        Returns metadata about the currently loaded Scope25.Purview module.
    .DESCRIPTION
        Diagnostic cmdlet with no external dependencies and no tenant
        connection required. Useful for confirming the module imported
        correctly and for including in support tickets.
    .EXAMPLE
        Get-Scope25ModuleInfo
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    [pscustomobject]@{
        ModuleName    = 'Scope25.Purview'
        ModuleVersion = $Script:Scope25Version
        ModuleRoot    = $Script:Scope25ModuleRoot
        Licence       = 'Apache-2.0 (logiciel libre)'
        PSVersion     = $PSVersionTable.PSVersion.ToString()
        PSEdition     = $PSVersionTable.PSEdition
    }
}

function Test-Scope25Prerequisites {
    <#
    .SYNOPSIS
        Contrôle préalable : vérifie que ce poste et cette session peuvent exécuter l'outil.
    .DESCRIPTION
        Lecture seule, aucune connexion ouverte, aucune modification. À exécuter avant l'étape 1 et
        de nouveau avant l'étape 2 : les deux étapes n'ont pas les mêmes exigences.

        Vérifie la version de PowerShell, les modules requis, la stratégie d'exécution, le protocole
        TLS sous Windows PowerShell 5.1, l'accès en écriture aux dossiers de sortie, et l'état des
        sessions Graph et Security & Compliance.

        Ce que cette fonction NE PEUT PAS vérifier, et qu'il faut confirmer soi-même :

          - LE NIVEAU DE LICENCE. L'explorateur de contenu, dont dépend tout l'inventaire de
            l'étape 2, exige Microsoft 365 E5/A5/G5 ou le module de conformité E5. Sans lui,
            l'étape 1 fonctionne normalement mais le camembert, la cartographie et les comptes
            d'étiquettes resteront vides. C'est la contrainte la plus coûteuse du projet et elle
            ne se découvre pas au moment de générer le rapport.
          - LES RÔLES ATTRIBUÉS. Une session ouverte ne dit pas quels rôles la porte.
          - LA COUVERTURE D'INDEXATION. Voir le README.
    .EXAMPLE
        Test-Scope25Prerequisites
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $resultats = [System.Collections.Generic.List[psobject]]::new()
    function Add-Check {
        param($Categorie, $Element, $Etat, $Detail)
        $resultats.Add([pscustomobject]@{ Categorie = $Categorie; Element = $Element; Etat = $Etat; Detail = $Detail })
    }

    # --- Runtime ---
    $psOk = $PSVersionTable.PSVersion -ge [version]'5.1'
    Add-Check 'Exécution' 'Version de PowerShell' $(if ($psOk) { 'OK' } else { 'BLOQUANT' }) `
        "$($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)). Minimum 5.1; 7.4 ou plus récent recommandé."

    try {
        $pol = Get-ExecutionPolicy -ErrorAction Stop
        $polOk = $pol -notin @('Restricted','AllSigned')
        Add-Check 'Exécution' 'Stratégie d''exécution' $(if ($polOk) { 'OK' } else { 'À CORRIGER' }) `
            "$pol$(if (-not $polOk) { ' - utiliser RemoteSigned : Set-ExecutionPolicy -Scope CurrentUser RemoteSigned' })"
    } catch {
        Add-Check 'Exécution' 'Stratégie d''exécution' 'INCONNU' 'Non applicable sur cette plateforme.'
    }

    # TLS 1.2 must be forced on Windows PowerShell 5.1; PS 7 negotiates it already.
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        $tlsOk = ([Net.ServicePointManager]::SecurityProtocol -band [Net.SecurityProtocolType]::Tls12) -ne 0
        Add-Check 'Exécution' 'TLS 1.2' $(if ($tlsOk) { 'OK' } else { 'À CORRIGER' }) `
            $(if ($tlsOk) { 'Activé.' } else { 'Requis par les services Microsoft 365 : [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12' })
    } else {
        Add-Check 'Exécution' 'TLS 1.2' 'OK' 'Négocié automatiquement par PowerShell 7.'
    }

    # --- Modules ---
    $modules = @(
        @{ Nom = 'ExchangeOnlineManagement';       Min = '3.0.0'; Usage = 'Étapes 1 et 2 - Security & Compliance PowerShell'; Bloquant = $true }
        @{ Nom = 'Microsoft.Graph.Authentication'; Min = '2.0.0'; Usage = 'Étape 2 - Connect-Scope25Tenant';                  Bloquant = $false }
        @{ Nom = 'Microsoft.Graph.Identity.Partner'; Min = '2.0.0'; Usage = 'Facultatif - découverte GDAP pour les MSSP';     Bloquant = $false }
    )
    foreach ($m in $modules) {
        $found = Get-Module -ListAvailable -Name $m.Nom | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $found) {
            Add-Check 'Modules' $m.Nom $(if ($m.Bloquant) { 'BLOQUANT' } else { 'ABSENT' }) `
                "Non installé. $($m.Usage). Install-Module $($m.Nom) -Scope CurrentUser"
        } elseif ($found.Version -lt [version]$m.Min) {
            Add-Check 'Modules' $m.Nom 'À METTRE À JOUR' "Version $($found.Version); minimum suggéré $($m.Min). $($m.Usage)"
        } else {
            Add-Check 'Modules' $m.Nom 'OK' "Version $($found.Version). $($m.Usage)"
        }
    }

    # --- Sessions ---
    $graph = $null
    if (Get-Command 'Get-MgContext' -ErrorAction SilentlyContinue) { $graph = Get-MgContext }
    Add-Check 'Sessions' 'Microsoft Graph' $(if ($graph) { 'OK' } else { 'NON CONNECTÉ' }) `
        $(if ($graph) { "Tenant $($graph.TenantId), compte $($graph.Account)" } else { 'Connect-Scope25Tenant' })

    $scc = [bool](Get-Command 'Get-Label' -ErrorAction SilentlyContinue)
    Add-Check 'Sessions' 'Security & Compliance' $(if ($scc) { 'OK' } else { 'NON CONNECTÉ' }) `
        $(if ($scc) { 'Cmdlets disponibles.' } else { 'Connect-IPPSSession' })

    # --- Écriture ---
    $logDir = if ($env:ProgramData) { Join-Path $env:ProgramData 'Scope25.Purview' } else { Join-Path $HOME '.scope25-purview' }
    $dl     = Join-Path $HOME 'Downloads'
    foreach ($d in @(@{ P = $logDir; N = 'Journal opérationnel' }, @{ P = $dl; N = 'Dossier des rapports' })) {
        $ok = $false; $detail = ''
        try {
            if (-not (Test-Path $d.P)) { New-Item -Path $d.P -ItemType Directory -Force -ErrorAction Stop | Out-Null }
            $probe = Join-Path $d.P ".scope25-write-test"
            Set-Content -Path $probe -Value 'test' -ErrorAction Stop
            Remove-Item $probe -Force -ErrorAction SilentlyContinue
            $ok = $true; $detail = $d.P
        } catch { $detail = "$($d.P) - écriture refusée : $($_.Exception.Message)" }
        Add-Check 'Écriture' $d.N $(if ($ok) { 'OK' } else { 'À CORRIGER' }) $detail
    }

    # --- Ce qui ne peut pas être vérifié depuis ici ---
    Add-Check 'À confirmer' 'Licence Microsoft 365' 'MANUEL' `
        'L''explorateur de contenu exige E5/A5/G5 ou le module de conformité E5. Sans lui, l''étape 2 ne produira aucun inventaire. Essai Purview de 90 jours disponible pour évaluer.'
    Add-Check 'À confirmer' 'Rôles attribués' 'MANUEL' `
        'Étape 1 : Compliance Administrator. Étape 2 : un rôle d''accès (Compliance Administrator, Compliance Data Administrator, Security Administrator ou Global Administrator) ET, séparément, Content Explorer List Viewer. Ces deux groupes ne sont pas cumulatifs.'
    Add-Check 'À confirmer' 'Journalisation d''audit' 'MANUEL' `
        'La journalisation d''audit unifiée doit être activée; plusieurs contrôles du domaine Incidents en dépendent.'

    $resultats
}

function Connect-Scope25Tenant {
    <#
    .SYNOPSIS
        Connects to a Microsoft 365 tenant with the least-privilege Graph scopes Scope25 needs.
    .DESCRIPTION
        Thin wrapper around Connect-MgGraph. Two supported patterns:

        - Direct / single-tenant: omit -TenantId to sign in against your own organization.
        - MSSP / GDAP: pass -TenantId with a customer's tenant ID or verified domain. This
          only works if (a) a GDAP relationship already exists between your organization and
          that customer, (b) your account is a member of the Entra ID security group mapped to
          that relationship, and (c) the Microsoft Graph Command Line Tools application (or
          your own multi-tenant app, if you pass -ClientId) has been authorized inside the
          CUSTOMER tenant. That third point trips people up constantly - if sign-in fails with
          "AADSTS90099: ... has not been authorized in the tenant", that's what it means; the
          customer's Global Administrator (or you, if your GDAP role allows it) needs to
          consent to the app inside that tenant once, and it works from then on. This cmdlet
          catches that specific error and rewrites the message to say so. Use
          Get-Scope25DelegatedTenant first if you don't already know the customer's tenant ID.

        Default scopes are workload-scoped on purpose, not one broad grant:
        AuditLogsQuery-Entra.Read.All, AuditLog.Read.All, Directory.Read.All, Reports.Read.All.
        Pass -Scopes to override - for example, add AuditLogsQuery-Exchange.Read.All once a
        Phase 3 control needs Exchange audit data specifically, rather than requesting it by
        default for every connection.

        Honesty note on automation: this is DELEGATED (interactive, signed-in-user)
        authentication - the well-documented, Microsoft-recommended way to use GDAP. It is not
        the same thing as unattended/scheduled automation. True app-only access across many
        GDAP customer tenants is a genuinely unresolved friction point in the Microsoft
        ecosystem right now; the old DAP-era "Secure Application Model" does not carry over
        cleanly. Don't build a scheduled task around this cmdlet expecting silent, no-prompt
        execution against a fleet of client tenants - that's a platform limitation, not
        something this module works around.
    .PARAMETER TenantId
        Customer tenant ID or verified domain. Omit to connect to your own organization.
    .PARAMETER Scopes
        Graph scopes to request. Defaults to the least-privilege audit/reporting set described
        above.
    .PARAMETER ClientId
        Application (client) ID to sign in with. Omit to use the Graph PowerShell SDK's own
        default multi-tenant app. Once you register your own branded multi-tenant Entra app -
        recommended for a commercial product, since it shows your product's name on the
        consent screen instead of "Microsoft Graph Command Line Tools" and avoids permission
        creep on a shared app you don't control - pass its App ID here.
    .PARAMETER UseDeviceCode
        Use the device code flow instead of an interactive browser popup - useful over SSH or
        on a machine without a browser.
    .EXAMPLE
        Connect-Scope25Tenant

        Connects to your own organization with the default least-privilege scopes.
    .EXAMPLE
        Connect-Scope25Tenant -TenantId 'contoso.onmicrosoft.com'

        Connects to a customer tenant through an existing GDAP relationship.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [string]$TenantId,

        [Parameter()]
        [string[]]$Scopes = $Script:Scope25DefaultGraphScopes,

        [Parameter()]
        [string]$ClientId,

        [Parameter()]
        [switch]$UseDeviceCode
    )

    if (-not (Get-Command -Name 'Connect-MgGraph' -ErrorAction SilentlyContinue)) {
        throw 'Connect-MgGraph is not available. Install-Module Microsoft.Graph.Authentication -Scope CurrentUser, then try again.'
    }

    $connectParams = @{
        Scopes    = $Scopes
        NoWelcome = $true
    }
    if ($TenantId)      { $connectParams['TenantId'] = $TenantId }
    if ($ClientId)      { $connectParams['ClientId'] = $ClientId }
    if ($UseDeviceCode) { $connectParams['UseDeviceCode'] = $true }

    try {
        Connect-MgGraph @connectParams
    } catch {
        if ($_.Exception.Message -match 'AADSTS90099') {
            throw "Sign-in failed: the application has not been authorized in that customer tenant yet (AADSTS90099). This is a one-time step per customer - their Global Administrator (or you, if your GDAP role permits it) needs to consent to the Microsoft Graph Command Line Tools application (or your own -ClientId, if you passed one) inside that tenant. After that, this cmdlet will work for that customer going forward. Original error: $($_.Exception.Message)"
        }
        throw
    }

    Get-Scope25ConnectionInfo
}

function Disconnect-Scope25Tenant {
    <#
    .SYNOPSIS
        Ends the current Microsoft Graph session.
    .DESCRIPTION
        Thin wrapper around Disconnect-MgGraph. Worth having as its own cmdlet in an
        MSSP/multi-tenant tool specifically so it's easy to remember to run between clients -
        staying signed in to Client A's tenant while intending to start work on Client B is
        exactly the kind of mistake a small wrapper cmdlet should make harder, not easier.
    .EXAMPLE
        Disconnect-Scope25Tenant
    #>
    [CmdletBinding()]
    param()

    if (-not (Get-Command -Name 'Get-MgContext' -ErrorAction SilentlyContinue)) {
        # Le module s'importe volontairement sans Microsoft.Graph. Sans ce garde-fou,
        # la commande echouait avec une CommandNotFoundException brute.
        Write-Verbose 'Microsoft.Graph.Authentication n''est pas installé : aucune session Graph ne peut exister.'
        return
    }

    if (Get-MgContext) {
        Disconnect-MgGraph | Out-Null
        Write-Verbose 'Session Graph fermée.'
    } else {
        Write-Verbose 'Aucune session Graph active.'
    }
}

function Get-Scope25ConnectionInfo {
    <#
    .SYNOPSIS
        Shows what tenant and scopes the current Graph session is actually connected to.
    .DESCRIPTION
        Wraps Get-MgContext. Worth running at the start of every session and every time you
        switch client tenants - confirming you're pointed at the tenant you think you are is
        cheap insurance against auditing, or worse writing to, the wrong customer. Called
        automatically at the end of Connect-Scope25Tenant.
    .EXAMPLE
        Get-Scope25ConnectionInfo
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    if (-not (Get-Command -Name 'Get-MgContext' -ErrorAction SilentlyContinue)) {
        Write-Warning 'Microsoft.Graph.Authentication n''est pas installé. Install-Module Microsoft.Graph.Authentication -Scope CurrentUser, puis Connect-Scope25Tenant.'
        return
    }

    $context = Get-MgContext

    if (-not $context) {
        Write-Warning 'Aucune session Graph active. Exécutez Connect-Scope25Tenant.'
        return
    }

    [pscustomobject]@{
        TenantId = $context.TenantId
        Account  = $context.Account
        AppName  = $context.AppName
        AuthType = $context.AuthType
        Scopes   = $context.Scopes -join ', '
    }
}

function Get-Scope25DelegatedTenant {
    <#
    .SYNOPSIS
        Lists the GDAP customer relationships available to your own organization.
    .DESCRIPTION
        Connects to YOUR OWN tenant - not a customer's, no -TenantId involved here - with the
        single scope this needs (DelegatedAdminRelationship.Read.All), and lists active GDAP
        relationships via Get-MgTenantRelationshipDelegatedAdminRelationship. Use this to find
        a customer's tenant ID before calling Connect-Scope25Tenant -TenantId <that ID>.

        This opens its own connection, separate from any customer-tenant connection you may
        already have through Connect-Scope25Tenant - reconnect to the customer tenant
        afterward for the actual audit work. Requires the Microsoft.Graph.Identity.Partner
        module (a different submodule from Microsoft.Graph.Authentication).

        Role names are resolved on a best-effort basis via Get-MgDirectoryRoleTemplate - GDAP
        stores each granted role as a bare GUID (roleDefinitionId), and this specific lookup
        was not verified against a live GDAP relationship in the environment that generated
        this module. If a GUID doesn't resolve to a name, it's shown as-is rather than guessed
        at - a raw GUID you can look up is more honest than a plausible-looking wrong label.
    .EXAMPLE
        Get-Scope25DelegatedTenant
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    if (-not (Get-Command -Name 'Get-MgTenantRelationshipDelegatedAdminRelationship' -ErrorAction SilentlyContinue)) {
        throw 'Get-MgTenantRelationshipDelegatedAdminRelationship is not available. Install-Module Microsoft.Graph.Identity.Partner -Scope CurrentUser, then try again.'
    }

    Connect-MgGraph -Scopes 'DelegatedAdminRelationship.Read.All' -NoWelcome

    $roleNameLookup = @{}
    try {
        $roleTemplates = Get-MgDirectoryRoleTemplate -All -ErrorAction Stop
        foreach ($template in $roleTemplates) {
            $roleNameLookup[$template.Id] = $template.DisplayName
        }
    } catch {
        Write-Verbose "Could not resolve role template names; roles will be shown as GUIDs. $($_.Exception.Message)"
    }

    $relationships = Get-MgTenantRelationshipDelegatedAdminRelationship -All

    foreach ($rel in $relationships) {

        $roleNames = foreach ($roleAssignment in @($rel.AccessDetails.UnifiedRoles)) {
            $roleId = $roleAssignment.RoleDefinitionId
            if ($roleNameLookup.ContainsKey($roleId)) {
                $roleNameLookup[$roleId]
            } else {
                $roleId
            }
        }

        [pscustomobject]@{
            CustomerName     = $rel.Customer.DisplayName
            CustomerTenantId = $rel.Customer.TenantId
            RelationshipName = $rel.DisplayName
            Status           = $rel.Status
            Roles            = $roleNames -join ', '
            EndDateTime      = $rel.EndDateTime
        }
    }
}

function Import-Scope25QuebecSIT {
    <#
    .SYNOPSIS
        Imports the Scope25 custom Quebec sensitive information types into Microsoft Purview.
    .DESCRIPTION
        Wraps New-DlpSensitiveInformationTypeRulePackage to import the rule package defined in
        Templates/Quebec_SITs.xml. Four entities, every one anchored on a published structural
        format: the RAMQ health insurance number (date-encoded digits), the cheque transit and
        institution number (Payments Canada Standard 006), the Quebec civic address (Canada Post
        FSA format, G/H/J prefixes), and the NIREC civil-status number.

        Firearms-licence and recreational-permit detectors were removed rather than shipped at low
        confidence: neither has a published format, so both would have fired largely on
        coincidence. Run Test-Scope25SitPattern to verify the surviving patterns offline before
        importing.

        Driver's licence, Social Insurance Number, passport, credit/debit card, and bank
        account numbers are NOT in that file on purpose - Microsoft's built-in library already
        covers all of them. See the coverage-map comment at the top of Quebec_SITs.xml for the
        exact built-in type names to reference in DLP or auto-labeling policies instead of
        duplicating them here.

        This is a WRITE operation against the connected tenant. It supports -WhatIf/-Confirm
        and should run under a deliberately elevated identity (for example Compliance
        Administrator) kept separate from the day-to-day least-privilege reporting identity -
        see the Security section of README.md. Requires an active Security & Compliance
        PowerShell session (Connect-IPPSSession, ExchangeOnlineManagement module) - a
        different connection from the one Connect-Scope25Tenant establishes; this cmdlet does
        not open either connection itself.
    .PARAMETER Path
        Path to the rule package XML. Defaults to Quebec_SITs.xml in this module's Templates
        folder.
    .EXAMPLE
        Connect-IPPSSession -UserPrincipalName admin@contoso.onmicrosoft.com
        Import-Scope25QuebecSIT -WhatIf

        Preview only - reports what would be imported, changes nothing.
    .EXAMPLE
        Import-Scope25QuebecSIT -Confirm:$false

        Imports without an interactive prompt. Verify afterwards in the Microsoft Purview
        portal under Data classification > Sensitive info types (Publisher column =
        Scope25.Purview).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Path = (Join-Path -Path (Join-Path -Path $Script:Scope25ModuleRoot -ChildPath 'Templates') -ChildPath 'Quebec_SITs.xml')
    )

    if (-not (Get-Command -Name 'New-DlpSensitiveInformationTypeRulePackage' -ErrorAction SilentlyContinue)) {
        throw 'No active Security & Compliance PowerShell session was found. Run Connect-IPPSSession (ExchangeOnlineManagement module) with an account that holds the Compliance Administrator role, then try again.'
    }

    if (-not (Test-Path -Path $Path)) {
        throw "Rule package not found at '$Path'."
    }

    $rawContent = Get-Content -Path $Path -Raw -ErrorAction Stop
    try {
        $null = [xml]$rawContent
    } catch {
        throw "The file at '$Path' is not well-formed XML: $($_.Exception.Message)"
    }

    $target = "Custom SIT rule package at '$Path'"
    if ($PSCmdlet.ShouldProcess($target, 'Import into Microsoft Purview via New-DlpSensitiveInformationTypeRulePackage')) {
        $fileBytes    = [System.IO.File]::ReadAllBytes($Path)
        $importResult = New-DlpSensitiveInformationTypeRulePackage -FileData $fileBytes -Confirm:$false

        [pscustomobject]@{
            Imported   = $true
            SourceFile = $Path
            PortalPath = 'Microsoft Purview portal > Data classification > Sensitive info types (filter Publisher = Scope25.Purview)'
            Note       = 'Verify the imported types in the portal, then confirm indexing coverage before trusting any count. Test-Scope25SitPattern validates the patterns offline at any time.'
            Result     = $importResult
        }
    }
}

function Publish-Scope25SensitivityLabels {
    <#
    .SYNOPSIS
        Creates and publishes the four Scope25 report-category sensitivity labels: Health Data,
        ID, Financial Data, Address.
    .DESCRIPTION
        Wraps New-Label and New-LabelPolicy, driven by Templates/Scope25_Labels.json, so the
        four labels exist and can be applied - manually, to start - right away. Display names
        and tooltips are published in French, matching the French-first approach used
        everywhere else this module produces something an end user (not an administrator)
        sees.

        Auto-labeling (wiring the SITs from Import-Scope25QuebecSIT and Microsoft's built-ins
        to a label so it applies itself) is deliberately left as a documented manual step, not
        scripted here: chaining several sensitive information types into one
        New-AutoSensitivityLabelRule condition needs to be verified against a real tenant
        first, and auto-labeling additionally requires an E5 / Information Protection P2
        license that not every client tenant will have. Each returned result includes the
        SITs to condition on and a reminder to pilot with -Mode TestWithoutNotifications.

        Most client tenants already have their own label taxonomy (for example
        Public / Internal / Confidential). This cmdlet checks first: a label whose Name
        already exists is skipped, not overwritten, and a warning fires if the tenant already
        has other, unrelated labels, so you can confirm with the client whether these four
        should be new top-level labels or folded into their existing scheme before publishing
        this to end users.

        This is a WRITE operation against the connected tenant. It supports -WhatIf/-Confirm
        and requires the same Security & Compliance PowerShell session as Import-Scope25QuebecSIT.
    .PARAMETER TaxonomyPath
        Path to the label definitions JSON. Defaults to Scope25_Labels.json in this module's
        Templates folder.
    .EXAMPLE
        Connect-IPPSSession -UserPrincipalName admin@contoso.onmicrosoft.com
        Publish-Scope25SensitivityLabels -WhatIf
    .EXAMPLE
        Publish-Scope25SensitivityLabels -Confirm:$false

        Verify afterwards in the Microsoft Purview portal under Solutions > Information
        Protection > Sensitivity labels.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$TaxonomyPath = (Join-Path -Path (Join-Path -Path $Script:Scope25ModuleRoot -ChildPath 'Templates') -ChildPath 'Scope25_Labels.json')
    )

    if (-not (Get-Command -Name 'New-Label' -ErrorAction SilentlyContinue)) {
        throw 'No active Security & Compliance PowerShell session was found. Run Connect-IPPSSession (ExchangeOnlineManagement module) with an account that holds the Compliance Administrator role, then try again.'
    }

    if (-not (Test-Path -Path $TaxonomyPath)) {
        throw "Label definitions file not found at '$TaxonomyPath'."
    }

    try {
        $taxonomy = Get-Content -Path $TaxonomyPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Could not read or parse '$TaxonomyPath': $($_.Exception.Message)"
    }

    $existingLabels = @(Get-Label -ErrorAction Stop)
    $existingNames  = @($existingLabels | ForEach-Object { $_.Name })
    $plannedNames   = @($taxonomy.labels | ForEach-Object { $_.name })

    $unrelatedCount = @($existingLabels | Where-Object { $_.Name -notin $plannedNames }).Count
    if ($unrelatedCount -gt 0) {
        Write-Warning "This tenant already has $unrelatedCount sensitivity label(s) outside the Scope25 set. Confirm with the client whether the four Scope25 labels should be new top-level labels or folded into their existing scheme before publishing this to end users."
    }

    $results = foreach ($labelDef in $taxonomy.labels) {

        $sitNames      = @($labelDef.triggerSits)
        $autoLabelNote = "Not created automatically - configure by hand under Solutions > Information Protection > Auto-labeling in the Purview portal (New-AutoSensitivityLabelPolicy / New-AutoSensitivityLabelRule), after confirming E5 / Information Protection P2 licensing. Pilot with -Mode TestWithoutNotifications first. SITs to condition on: $($sitNames -join ', ')."

        if ($labelDef.name -in $existingNames) {
            [pscustomobject]@{
                LabelName            = $labelDef.name
                DisplayName          = $labelDef.displayNameFr
                Action               = 'Skipped - a label with this name already exists'
                TriggeringSITs       = $sitNames -join ', '
                AutoLabelingNextStep = $autoLabelNote
            }
            continue
        }

        $target = "Sensitivity label '$($labelDef.name)' ($($labelDef.displayNameFr) / $($labelDef.displayNameEn))"

        if ($PSCmdlet.ShouldProcess($target, 'Create (New-Label)')) {
            $newLabel = New-Label -Name $labelDef.name -DisplayName $labelDef.displayNameFr -Tooltip $labelDef.tooltipFr -Confirm:$false

            [pscustomobject]@{
                LabelName            = $labelDef.name
                DisplayName          = $labelDef.displayNameFr
                Action               = 'Created'
                TriggeringSITs       = $sitNames -join ', '
                AutoLabelingNextStep = $autoLabelNote
                LabelObject          = $newLabel
            }
        }
    }

    $createdNames = @($results | Where-Object { $_.Action -eq 'Created' } | ForEach-Object { $_.LabelName })
    if ($createdNames.Count -gt 0) {
        if ($PSCmdlet.ShouldProcess('Scope25 - Loi 25 Labels', 'Publish label policy (New-LabelPolicy)')) {
            New-LabelPolicy -Name 'Scope25 - Loi 25 Labels' -Labels $createdNames -Confirm:$false | Out-Null
        }
    }

    $results
}

function Get-Scope25LabelCoverage {
    <#
    .SYNOPSIS
        Returns an item count per Scope25 report-category label, for the compliance report.
    .DESCRIPTION
        Wraps Export-ContentExplorerData with -TagType Sensitivity -Aggregate, which returns a
        total count rather than item-level file details. That's a deliberate least-privilege
        and data-minimization choice: a compliance report needs "how many", not "which exact
        files" or their contents, so the Content Explorer List Viewer role (Data Classification
        List Viewer) is sufficient - Content Explorer Content Viewer is not required for this
        cmdlet and should not be requested for it.
    .PARAMETER TaxonomyPath
        Path to the label definitions JSON. Defaults to Scope25_Labels.json in this module's
        Templates folder.
    .EXAMPLE
        Get-Scope25LabelCoverage
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$TaxonomyPath = (Join-Path -Path (Join-Path -Path $Script:Scope25ModuleRoot -ChildPath 'Templates') -ChildPath 'Scope25_Labels.json')
    )

    if (-not (Test-Path -Path $TaxonomyPath)) {
        throw "Label definitions file not found at '$TaxonomyPath'."
    }

    if (-not (Get-Command -Name 'Export-ContentExplorerData' -ErrorAction SilentlyContinue)) {
        throw 'Export-ContentExplorerData is not available in this session. Connect to Security & Compliance PowerShell first, and confirm the account holds the Content Explorer List Viewer role.'
    }

    $taxonomy = Get-Content -Path $TaxonomyPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

    foreach ($labelDef in $taxonomy.labels) {

        $itemCount = 0
        try {
            $result = Export-ContentExplorerData -TagName $labelDef.name -TagType 'Sensitivity' -Aggregate -WarningAction SilentlyContinue
            if ($null -ne $result -and $null -ne $result.TotalCount) {
                $itemCount = $result.TotalCount
            }
        } catch {
            Write-Warning "Could not retrieve a count for label '$($labelDef.name)': $($_.Exception.Message)"
        }

        [pscustomobject]@{
            LabelName     = $labelDef.name
            DisplayNameEn = $labelDef.displayNameEn
            DisplayNameFr = $labelDef.displayNameFr
            ItemCount     = $itemCount
        }
    }
}

function Write-Scope25AuditLog {
    <#
    .SYNOPSIS
        Appends a tamper-evident line to the Scope25 operational log.
    .DESCRIPTION
        Records who ran a Scope25 action, when, and against which tenant. This exists because
        Microsoft Purview does NOT expose a native "created by / created on" field for a custom
        sensitive information type or a sensitivity label - so once Import-Scope25QuebecSIT or
        Publish-Scope25SensitivityLabels has run, nothing in the Purview UI records who did it.
        This log is the only record.

        Deliberately written OUTSIDE the Downloads folder. The human-readable report goes to
        Downloads (Phase 5); the evidentiary trail goes to a separate, less casually-edited
        location - by default %ProgramData%\Scope25.Purview\Logs on Windows, or
        ~/.scope25-purview/logs elsewhere. Override with -LogDirectory.

        Honest limitation: this is append-only by convention, not by enforcement. A local
        administrator can edit or delete the file. Each entry carries a SHA256 hash chaining it
        to the previous entry, so undetected tampering requires rewriting every subsequent line -
        that makes casual edits visible, but it is not a substitute for shipping these entries to
        a write-once store or SIEM, which is what a client with real evidentiary requirements
        should do.
    .PARAMETER Action
        Short action identifier, e.g. 'Import-Scope25QuebecSIT' or 'Assessment'.
    .PARAMETER Outcome
        Result of the action, e.g. 'Success', 'WhatIf', 'Failed'.
    .PARAMETER Detail
        Optional free-text detail.
    .PARAMETER LogDirectory
        Override the default log location.
    .EXAMPLE
        Write-Scope25AuditLog -Action 'Assessment' -Outcome 'Success' -Detail '34 controls evaluated'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Action,
        [Parameter()][string]$Outcome = 'Success',
        [Parameter()][string]$Detail  = '',
        [Parameter()][string]$LogDirectory
    )

    if (-not $LogDirectory) {
        if ($env:ProgramData) {
            $LogDirectory = Join-Path $env:ProgramData 'Scope25.Purview\Logs'
        } else {
            $LogDirectory = Join-Path $HOME '.scope25-purview/logs'
        }
    }

    if (-not (Test-Path -Path $LogDirectory)) {
        New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
    }

    $logPath = Join-Path $LogDirectory 'scope25-operations.log'

    # Identity: prefer the signed-in Graph account, fall back to the OS user.
    $account  = $null
    $tenantId = $null
    if (Get-Command -Name 'Get-MgContext' -ErrorAction SilentlyContinue) {
        $ctx = Get-MgContext
        if ($ctx) { $account = $ctx.Account; $tenantId = $ctx.TenantId }
    }
    if (-not $account) { $account = "$($env:USERDOMAIN)\$($env:USERNAME)".Trim('\') }
    if (-not $account) { $account = $env:USER }
    if (-not $tenantId) { $tenantId = 'n/a' }

    # Hash-chain to the previous entry so that silent edits become detectable.
    $previousHash = '0' * 64
    if (Test-Path -Path $logPath) {
        $lastLine = Get-Content -Path $logPath -Tail 1 -ErrorAction SilentlyContinue
        if ($lastLine) {
            $sha    = [System.Security.Cryptography.SHA256]::Create()
            $bytes  = [System.Text.Encoding]::UTF8.GetBytes($lastLine)
            $previousHash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
            $sha.Dispose()
        }
    }

    $entry = [pscustomobject]@{
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        Account      = $account
        TenantId     = $tenantId
        Machine      = $env:COMPUTERNAME
        Module       = 'Scope25.Purview'
        Version      = $Script:Scope25Version
        Action       = $Action
        Outcome      = $Outcome
        Detail       = $Detail
        PreviousHash = $previousHash
    }

    ($entry | ConvertTo-Json -Compress) | Add-Content -Path $logPath -Encoding UTF8
    Write-Verbose "Logged '$Action' to $logPath"
    $entry
}

function Invoke-Scope25Loi25Assessment {
    <#
    .SYNOPSIS
        Evaluates the connected tenant against the Scope25 Loi 25 control library.
    .DESCRIPTION
        Reads Templates/Loi25_Template.json and evaluates every control that can be checked from
        tenant configuration, returning a structured result per control plus a weighted score.
        Read-only: this cmdlet changes nothing.

        Scoring is reported per tier, never as one blended number. Automated controls produce
        Pass / Fail / Unknown; flagged controls produce Review; attestation controls always
        produce NotAssessed and are counted separately, because a tool that scored them would be
        claiming to verify things it cannot see. A single headline percentage would be the most
        marketable output and the least defensible one - if a client's CAI file ever turns
        adversarial, "our tool said 87%" is exactly the sentence you do not want to explain.

        Requires the Security & Compliance PowerShell session (Connect-IPPSSession) for Purview
        checks, and the Graph session (Connect-Scope25Tenant) for Entra checks. Whichever is
        missing simply yields Unknown for the affected controls rather than failing the run.

        NOT VALIDATED AGAINST A LIVE TENANT. Every cmdlet call below is wrapped so a missing or
        renamed cmdlet degrades to Unknown instead of throwing. Treat the first real run as a
        debugging exercise, not a client deliverable.
    .PARAMETER TemplatePath
        Path to the control library JSON.
    .PARAMETER SkipAuditLog
        Do not write an entry to the Scope25 operational log.
    .EXAMPLE
        Connect-Scope25Tenant
        Connect-IPPSSession -UserPrincipalName admin@contoso.onmicrosoft.com
        Invoke-Scope25Loi25Assessment | Format-Table ControlId, Tier, Status, Title
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$TemplatePath = (Join-Path -Path (Join-Path -Path $Script:Scope25ModuleRoot -ChildPath 'Templates') -ChildPath 'Loi25_Template.json'),

        [Parameter()]
        [switch]$SkipAuditLog,

        # Étape 1 : produire le référentiel sans interroger le tenant. À ce moment-là,
        # rien n'a encore été classé selon les nouveaux détecteurs, donc tout constat
        # serait faux plutôt qu'incomplet.
        [Parameter()]
        [switch]$GuideOnly
    )

    if (-not (Test-Path -Path $TemplatePath)) {
        throw "Control library not found at '$TemplatePath'."
    }

    $library = Get-Content -Path $TemplatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

    # --- helper: run a probe safely, returning Pass/Fail/Unknown plus evidence text ---
    function Invoke-Scope25Probe {
        param([scriptblock]$Probe)
        try {
            & $Probe
        } catch {
            [pscustomobject]@{ Status = 'Indisponible'; Evidence = "La sonde n'a pas pu s'exécuter : $($_.Exception.Message)" }
        }
    }

    if ($GuideOnly) {
        $results = foreach ($domain in $library.domains) {
            foreach ($control in $domain.controls) {
                [pscustomobject]@{
                    DomainId    = $domain.id
                    Domain      = $domain.titleFr
                    ControlId   = $control.id
                    Title       = $control.titleFr
                    Tier        = $control.tier
                    Weight      = $control.weight
                    Status      = 'Guide'
                    Evidence    = ''
                    Obligation  = $control.obligationFr
                    Remediation = $control.remediationFr
                    CaiTheme    = $control.cai_theme
                }
            }
        }
        return $results
    }

    $haveScc   = [bool](Get-Command -Name 'Get-RetentionCompliancePolicy' -ErrorAction SilentlyContinue)
    $haveGraph = $false
    if (Get-Command -Name 'Get-MgContext' -ErrorAction SilentlyContinue) {
        $haveGraph = [bool](Get-MgContext)
    }

    if (-not $haveScc)   { Write-Warning 'Aucune session Security & Compliance PowerShell détectée. Les constats Purview seront marqués « Indisponible ». Exécutez Connect-IPPSSession.' }
    if (-not $haveGraph) { Write-Warning 'Aucune session Microsoft Graph détectée. Les constats Entra seront marqués « Indisponible ». Exécutez Connect-Scope25Tenant.' }

    # --- probe table: control id -> scriptblock. Controls absent here are not machine-checkable. ---
    $probes = @{

        'CONS-01' = {
            if (-not $haveScc) { return [pscustomobject]@{ Status='Indisponible'; Evidence='Aucune session Security & Compliance PowerShell : ce constat n''a pas pu être recueilli.' } }
            $pols = @(Get-RetentionCompliancePolicy -ErrorAction Stop)
            $enabled = @($pols | Where-Object { $_.Enabled -eq $true })
            if ($enabled.Count -gt 0) {
                [pscustomobject]@{ Status='Recueillie'; Evidence="$($enabled.Count) politique(s) de rétention active(s) sur $($pols.Count) définie(s)." }
            } else {
                [pscustomobject]@{ Status='Recueillie'; Evidence='Aucune politique de rétention active trouvée.' }
            }
        }

        'SENS-01' = {
            if (-not $haveScc) { return [pscustomobject]@{ Status='Indisponible'; Evidence='Aucune session Security & Compliance PowerShell : ce constat n''a pas pu être recueilli.' } }
            if (-not (Get-Command 'Get-DlpSensitiveInformationType' -ErrorAction SilentlyContinue)) {
                return [pscustomobject]@{ Status='Indisponible'; Evidence='Cmdlet Get-DlpSensitiveInformationType indisponible.' }
            }
            $sits = @(Get-DlpSensitiveInformationType -ErrorAction Stop)
            $scope25 = @($sits | Where-Object { $_.Publisher -like '*Scope25*' })
            if ($scope25.Count -gt 0) {
                [pscustomobject]@{ Status='Recueillie'; Evidence="$($scope25.Count) SIT Scope25 importé(s) : $(($scope25.Name | Select-Object -First 6) -join ', ')." }
            } else {
                [pscustomobject]@{ Status='Recueillie'; Evidence='Aucun SIT Scope25 trouvé. Exécuter Import-Scope25QuebecSIT.' }
            }
        }

        'SENS-02' = {
            if (-not $haveScc) { return [pscustomobject]@{ Status='Indisponible'; Evidence='Aucune session Security & Compliance PowerShell : ce constat n''a pas pu être recueilli.' } }
            $labels = @(Get-Label -ErrorAction Stop | Where-Object { $_.Name -like 'Scope25-*' })
            $policies = @()
            if (Get-Command 'Get-LabelPolicy' -ErrorAction SilentlyContinue) {
                $policies = @(Get-LabelPolicy -ErrorAction SilentlyContinue)
            }
            if ($labels.Count -ge 4 -and $policies.Count -gt 0) {
                [pscustomobject]@{ Status='Recueillie'; Evidence="$($labels.Count) étiquette(s) Scope25 créée(s), $($policies.Count) politique(s) de publication." }
            } elseif ($labels.Count -gt 0) {
                [pscustomobject]@{ Status='Recueillie'; Evidence="$($labels.Count) étiquette(s) Scope25 créée(s) mais aucune politique de publication détectée." }
            } else {
                [pscustomobject]@{ Status='Recueillie'; Evidence='Aucune étiquette Scope25 trouvée. Exécuter Publish-Scope25SensitivityLabels.' }
            }
        }

        'SENS-03' = {
            if (-not $haveScc) { return [pscustomobject]@{ Status='Indisponible'; Evidence='Aucune session Security & Compliance PowerShell : ce constat n''a pas pu être recueilli.' } }
            $cov = @(Get-Scope25LabelCoverage -ErrorAction Stop)
            $total = ($cov | Measure-Object -Property ItemCount -Sum).Sum
            [pscustomobject]@{ Status='Recueillie'; Evidence="Total étiqueté : $total élément(s). Détail par catégorie : $(($cov | ForEach-Object { "$($_.DisplayNameFr)=$($_.ItemCount)" }) -join ', '). Un total de 0 peut signifier soit aucune donnée sensible, soit un étiquetage non déployé - à interpréter avec le client." }
        }

        'SENS-04' = {
            if (-not $haveScc) { return [pscustomobject]@{ Status='Indisponible'; Evidence='Aucune session Security & Compliance PowerShell : ce constat n''a pas pu être recueilli.' } }
            if (-not (Get-Command 'Get-DlpCompliancePolicy' -ErrorAction SilentlyContinue)) {
                return [pscustomobject]@{ Status='Indisponible'; Evidence='Cmdlet Get-DlpCompliancePolicy indisponible.' }
            }
            $dlp = @(Get-DlpCompliancePolicy -ErrorAction Stop | Where-Object { $_.Enabled -eq $true -or $_.Mode -like '*Enable*' })
            if ($dlp.Count -gt 0) {
                [pscustomobject]@{ Status='Recueillie'; Evidence="$($dlp.Count) politique(s) DLP active(s)." }
            } else {
                [pscustomobject]@{ Status='Recueillie'; Evidence='Aucune politique DLP active trouvée.' }
            }
        }

        'SEC-01' = {
            if (-not $haveScc) { return [pscustomobject]@{ Status='Indisponible'; Evidence='Aucune session Security & Compliance PowerShell : ce constat n''a pas pu être recueilli.' } }
            if (-not (Get-Command 'Get-AdminAuditLogConfig' -ErrorAction SilentlyContinue)) {
                return [pscustomobject]@{ Status='Indisponible'; Evidence='Cmdlet Get-AdminAuditLogConfig indisponible (session Exchange Online requise).' }
            }
            $cfg = Get-AdminAuditLogConfig -ErrorAction Stop
            if ($cfg.UnifiedAuditLogIngestionEnabled) {
                [pscustomobject]@{ Status='Recueillie'; Evidence='Journalisation d''audit unifiée activée.' }
            } else {
                [pscustomobject]@{ Status='Recueillie'; Evidence='Journalisation d''audit unifiée DÉSACTIVÉE - plusieurs contrôles du domaine Incidents en dépendent.' }
            }
        }

        'SEC-04' = {
            if (-not $haveGraph) { return [pscustomobject]@{ Status='Indisponible'; Evidence='Aucune session Microsoft Graph : ce constat n''a pas pu être recueilli.' } }
            if (-not (Get-Command 'Get-MgUser' -ErrorAction SilentlyContinue)) {
                return [pscustomobject]@{ Status='Indisponible'; Evidence='Microsoft.Graph.Users non installé.' }
            }
            $guests = @(Get-MgUser -Filter "userType eq 'Guest'" -All -ErrorAction Stop)
            [pscustomobject]@{ Status='Recueillie'; Evidence="$($guests.Count) compte(s) invité(s) dans le tenant - inventaire à réviser, un invité légitime et un accès oublié se ressemblent dans les données." }
        }

        'XB-01' = {
            if (-not $haveGraph) { return [pscustomobject]@{ Status='Indisponible'; Evidence='Aucune session Microsoft Graph : ce constat n''a pas pu être recueilli.' } }
            if (-not (Get-Command 'Get-MgOrganization' -ErrorAction SilentlyContinue)) {
                return [pscustomobject]@{ Status='Indisponible'; Evidence='Microsoft.Graph.Identity.DirectoryManagement non installé.' }
            }
            $org = Get-MgOrganization -ErrorAction Stop | Select-Object -First 1
            $loc = $org.PreferredDataLocation
            if (-not $loc) { $loc = '(non défini)' }
            [pscustomobject]@{ Status='Recueillie'; Evidence="Pays du tenant : $($org.CountryLetterCode); emplacement de données préféré : $loc. Rappel : « au Canada » n'est pas « au Québec » - la Loi 25 vise la communication hors Québec." }
        }

        'GOV-06' = {
            $dir = if ($env:ProgramData) { Join-Path $env:ProgramData 'Scope25.Purview\Logs' } else { Join-Path $HOME '.scope25-purview/logs' }
            $path = Join-Path $dir 'scope25-operations.log'
            if (Test-Path $path) {
                $n = @(Get-Content -Path $path -ErrorAction SilentlyContinue).Count
                [pscustomobject]@{ Status='Recueillie'; Evidence="Journal opérationnel présent ($n entrée(s)) : $path" }
            } else {
                [pscustomobject]@{ Status='Recueillie'; Evidence="Aucun journal opérationnel trouvé à $path" }
            }
        }
    }

    $results = foreach ($domain in $library.domains) {
        foreach ($control in $domain.controls) {

            $status   = 'NotAssessed'
            $evidence = 'Contrôle par attestation - preuve à fournir manuellement.'

            if ($control.tier -ne 'attestation') {
                if ($probes.ContainsKey($control.id)) {
                    $probeResult = Invoke-Scope25Probe -Probe $probes[$control.id]
                    $status   = $probeResult.Status
                    $evidence = $probeResult.Evidence
                } else {
                    $status   = 'Indisponible'
                    $evidence = 'Sonde non encore implémentée dans cette version.'
                }
            }

            [pscustomobject]@{
                DomainId   = $domain.id
                Domain     = $domain.titleFr
                ControlId  = $control.id
                Title      = $control.titleFr
                Tier       = $control.tier
                Weight     = $control.weight
                Status     = $status
                Evidence   = $evidence
                Obligation = $control.obligationFr
                Remediation= $control.remediationFr
                CaiTheme   = $control.cai_theme
            }
        }
    }

    if (-not $SkipAuditLog) {
        $counts = $results | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
        Write-Scope25AuditLog -Action 'Invoke-Scope25Loi25Assessment' -Outcome 'Success' `
            -Detail "$($results.Count) contrôles évalués; $($counts -join ', ')" | Out-Null
    }

    $results
}

function Get-Scope25AssessmentSummary {
    <#
    .SYNOPSIS
        Summarises what evidence the run was able to gather. Produces no compliance score.
    .DESCRIPTION
        There is deliberately no score here, and no pass/fail count, because this module does not
        decide whether an organisation complies with anything. Nearly every Loi 25 obligation turns
        on judgement a tool cannot make: whether a retention period is appropriate to the purpose,
        whether consent was validly obtained, whether an incident carries a risk of serious harm.
        A tool that printed "Conforme" next to those questions would be asserting something it has
        no way to know, and that assertion would end up in front of the Commission d'acces a
        l'information attached to someone's name.

        So the output is evidence availability only: what was collected, what could not be
        reached, and what has to be obtained from people. The verdict belongs to the reviewer.
    .EXAMPLE
        Invoke-Scope25Loi25Assessment | Get-Scope25AssessmentSummary
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [psobject[]]$AssessmentResult
    )

    begin { $all = [System.Collections.Generic.List[psobject]]::new() }
    process { foreach ($r in $AssessmentResult) { $all.Add($r) } }

    end {
        $collected   = @($all | Where-Object { $_.Status -eq 'Recueillie' })
        $unavailable = @($all | Where-Object { $_.Status -eq 'Indisponible' })
        $toObtain    = @($all | Where-Object { $_.Status -eq 'A recueillir' })

        [pscustomobject]@{
            TotalControls          = $all.Count
            EvidenceCollected      = $collected.Count
            EvidenceUnavailable    = $unavailable.Count
            EvidenceToObtain       = $toObtain.Count
            TechnicalSignalControls = @($all | Where-Object { $_.Tier -ne 'attestation' }).Count
            HumanEvidenceControls   = @($all | Where-Object { $_.Tier -eq 'attestation' }).Count
            Basis  = 'Dénombrement de la preuve disponible, non une evaluation de conformité.'
            Caveat = 'Aucun verdict n''est rendu par l''outil. Chaque constat doit etre interprété par une personne qualifiée : spécialiste Purview, responsable de la réponse aux incidents, conseiller en gestion de brèche et conseiller juridique.'
        }
    }
}

function New-Scope25Report {
    <#
    .SYNOPSIS
        Generates the interactive, printable Loi 25 compliance report.
    .DESCRIPTION
        Takes the output of Invoke-Scope25Loi25Assessment, merges it with the control library,
        injects the result into Templates/Report_Template.html, and writes a single self-contained
        HTML file to the Downloads folder. No CDN, no external assets - the report opens offline
        and will still render years from now, which matters for something a client may need to
        produce as evidence long after the audit.

        Two destinations on purpose:
          - The readable report goes to Downloads, where the technician expects it.
          - A separate entry goes to the Scope25 operational log (ProgramData or ~/.scope25-purview),
            recording who generated it and when. That log is deliberately NOT in Downloads: the
            human-readable artifact and the evidentiary trail should not sit in the same casually
            managed folder.

        The report never shows a single blended compliance score. It leads with the proportion of
        obligations that are machine-verifiable at all - a number that undersells the tool and
        protects the person who signs the report.

    .PARAMETER AssessmentResult
        Output of Invoke-Scope25Loi25Assessment. Accepts pipeline input.
    .PARAMETER OutputDirectory
        Override the destination. Defaults to the user's Downloads folder.
    .PARAMETER TemplatePath
        Override the HTML template.
    .PARAMETER TenantLabel
        Label shown as the audited tenant. Defaults to the connected Graph tenant, then to 'n/d'.
    .PARAMETER DataMap
        Output of Get-Scope25DataMap. Adds the "which data lives where" section to the report.
        Omit it and that section is simply not rendered.
    .PARAMETER SitDetection
        Output of Get-Scope25SitDetection. Adds the per-SIT breakdown and pie chart.
    .PARAMETER Mode
        Guide : le référentiel et les orientations, sans aucune donnée du tenant (étape 1).
        Audit : le rapport complet avec inventaire, emplacements et camembert (étape 2).
    .PARAMETER SitsImportedOn
        Date the custom SITs were imported into the tenant. Supply it and the report states plainly
        how long the environment has had to index against them - the difference between a trustworthy
        zero and a meaningless one.
    .PARAMETER PassThru
        Return the generated file path.
    .EXAMPLE
        Invoke-Scope25Loi25Assessment | New-Scope25Report

    .EXAMPLE
        $carte = Get-Scope25DataMap
        Invoke-Scope25Loi25Assessment | New-Scope25Report -DataMap $carte -TenantLabel 'Client ABC inc.'

    .EXAMPLE
        $r = Invoke-Scope25Loi25Assessment
        $r | New-Scope25Report -TenantLabel 'Client ABC inc.' -PassThru
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [psobject[]]$AssessmentResult,

        [Parameter()][string]$OutputDirectory,
        [Parameter()][string]$TemplatePath = (Join-Path -Path (Join-Path -Path $Script:Scope25ModuleRoot -ChildPath 'Templates') -ChildPath 'Report_Template.html'),
        [Parameter()][string]$LibraryPath  = (Join-Path -Path (Join-Path -Path $Script:Scope25ModuleRoot -ChildPath 'Templates') -ChildPath 'Loi25_Template.json'),
        [Parameter()][string]$TenantLabel,
        [Parameter()][psobject[]]$DataMap,
        [Parameter()][psobject[]]$SitDetection,
        [Parameter()][datetime]$SitsImportedOn,
        [Parameter()][ValidateSet('Guide','Audit')][string]$Mode = 'Audit',
        [Parameter()][switch]$PassThru
    )

    begin { $rows = [System.Collections.Generic.List[psobject]]::new() }
    process { foreach ($r in $AssessmentResult) { $rows.Add($r) } }

    end {
        if ($rows.Count -eq 0) { throw 'No assessment results were supplied. Run Invoke-Scope25Loi25Assessment first.' }

        if (-not (Test-Path -Path $TemplatePath)) { throw "Report template not found at '$TemplatePath'." }
        if (-not (Test-Path -Path $LibraryPath))  { throw "Control library not found at '$LibraryPath'." }

        $library = Get-Content -Path $LibraryPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

        # Destination: Downloads by default. Resolved defensively - the registry-free fallback
        # matters on PS 7 / non-Windows and on redirected profiles.
        if (-not $OutputDirectory) {
            $candidate = Join-Path -Path $HOME -ChildPath 'Downloads'
            if (-not (Test-Path -Path $candidate)) {
                $candidate = [Environment]::GetFolderPath('MyDocuments')
                Write-Verbose "Downloads folder not found; falling back to $candidate"
            }
            $OutputDirectory = $candidate
        }
        if (-not (Test-Path -Path $OutputDirectory)) {
            New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
        }

        # Identity and tenant, from the live Graph context where available.
        $account = $null; $tenant = $TenantLabel
        if (Get-Command -Name 'Get-MgContext' -ErrorAction SilentlyContinue) {
            $ctx = Get-MgContext
            if ($ctx) {
                $account = $ctx.Account
                if (-not $tenant) { $tenant = $ctx.TenantId }
            }
        }
        if (-not $account) { $account = "$($env:USERDOMAIN)\$($env:USERNAME)".Trim('\') }
        if (-not $account) { $account = $env:USER }
        if (-not $tenant)  { $tenant  = 'n/d' }

        $logDir = if ($env:ProgramData) { Join-Path $env:ProgramData 'Scope25.Purview\Logs' }
                  else { Join-Path $HOME '.scope25-purview/logs' }

        # Index the library so each result row can carry its obligation text and citation.
        $meta = @{}
        foreach ($domain in $library.domains) {
            foreach ($control in $domain.controls) { $meta[$control.id] = $control }
        }

        $summary = $rows | Get-Scope25AssessmentSummary

        $sitsOut = @()
        if ($SitDetection) {
            $sitsOut = foreach ($sit in ($SitDetection | Where-Object { $_.ItemCount -gt 0 } | Sort-Object -Property ItemCount -Descending)) {
                [ordered]@{ name = $sit.SitName; category = $sit.Category; source = $sit.Source; itemCount = $sit.ItemCount }
            }
        }

        $domainsOut = foreach ($domain in $library.domains) {
            $controlsOut = foreach ($control in $domain.controls) {
                $row = $rows | Where-Object { $_.ControlId -eq $control.id } | Select-Object -First 1
                $sap = ''
                if ($control.PSObject.Properties.Name -contains 'sapExposure') { $sap = $control.sapExposure }
                [ordered]@{
                    id           = $control.id
                    title        = $control.titleFr
                    tier         = $control.tier
                    status       = if ($row) { $row.Status }   else { 'Unknown' }
                    evidence     = if ($row) { $row.Evidence } else { '' }
                    obligation   = $control.obligationFr
                    legalBasis   = $control.legalBasis
                    remediation  = $control.remediationFr
                    sapExposure  = $sap
                }
            }
            [ordered]@{ id = $domain.id; title = $domain.titleFr; controls = @($controlsOut) }
        }

        $correction = ''
        if ($library.PSObject.Properties.Name -contains 'knownCorrections' -and $library.knownCorrections) {
            $correction = "Révision consignée ($($library.knownCorrections[0].control)) : $($library.knownCorrections[0].lesson)"
        }

        # Data map is optional. Kept coarse: category, workload, and only the endpoints the
        # operator explicitly asked for. Anything finer turns the report into a targeting map.
        $dataMapOut = $null
        if ($DataMap) {
            $anyEndpoints = [bool](@($DataMap | Where-Object { $_.EndpointDetail }).Count)
            $cats = foreach ($cat in $DataMap) {
                [ordered]@{
                    displayFr      = $cat.DisplayFr
                    dataTypesFr    = @($cat.DataTypesFr)
                    totalItems     = $cat.TotalItems
                    byWorkload     = @(foreach ($w in $cat.ByWorkload) { [ordered]@{ workload = $w.Workload; itemCount = $w.ItemCount } })
                    endpoints      = @(foreach ($e in $cat.Endpoints)   { [ordered]@{ type = $e.Type; name = $e.Name; itemCount = $e.ItemCount } })
                    classification = $cat.Classification
                    caiObligations = @($cat.CaiObligations)
                    caiAction      = $cat.CaiAction
                }
            }
            $intro = 'Vue d''ensemble des catégories de renseignements personnels détectées et des charges de travail où elles se trouvent. Les comptes proviennent de l''explorateur de contenu Purview et ne portent que sur le contenu étiqueté.'
            if (-not $anyEndpoints) {
                $intro += ' Les noms de points de terminaison ne sont pas inclus. Les boîtes aux lettres nominatives ne sont jamais énumérées.'
            }
            $dataMapOut = [ordered]@{ introFr = $intro; endpointDetail = $anyEndpoints; categories = @($cats) }
        }

        $payload = [ordered]@{
            meta = [ordered]@{
                tenant         = $tenant
                account        = $account
                generatedLocal = (Get-Date).ToString('yyyy-MM-dd HH:mm')
                moduleVersion  = $Script:Scope25Version
                frameworkLabel = $library.framework
                scope          = $library.scope
                logPath        = (Join-Path $logDir 'scope25-operations.log')
                sourceBasis    = $library.sourceBasis
                correctionNote = $correction
            }
            summary = [ordered]@{
                totalControls           = $summary.TotalControls
                evidenceCollected       = $summary.EvidenceCollected
                evidenceUnavailable     = $summary.EvidenceUnavailable
                evidenceToObtain        = $summary.EvidenceToObtain
                technicalSignalControls = $summary.TechnicalSignalControls
                humanEvidenceControls   = $summary.HumanEvidenceControls
                basis                   = $summary.Basis
                caveat                  = $summary.Caveat
            }
            sits = @($sitsOut)
            mode = $Mode
            freshness = [ordered]@{
                sitsImportedOn = if ($SitsImportedOn) { $SitsImportedOn.ToString('yyyy-MM-dd') } else { $null }
                daysSinceImport = if ($SitsImportedOn) { [int]((Get-Date) - $SitsImportedOn).TotalDays } else { $null }
            }
            dataMap = $dataMapOut
            domains = @($domainsOut)
        }

        # -Depth matters: the default of 2 silently truncates nested controls into type names.
        $json = $payload | ConvertTo-Json -Depth 10 -Compress

        # Guard against the one thing that would corrupt the injected script block.
        if ($json -match '</script') { throw 'Assessment data contains a script-closing sequence; refusing to generate the report.' }

        $template = Get-Content -Path $TemplatePath -Raw -ErrorAction Stop
        $pattern  = '(?s)/\*__SCOPE25_DATA__\*/.*?/\*__FIN_SCOPE25_DATA__\*/'
        if ($template -notmatch $pattern) { throw "Template at '$TemplatePath' is missing the Scope25 data placeholder." }
        $html = [regex]::Replace($template, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $json })

        $safeTenant = ($tenant -replace '[^\w\.\-]', '_')
        $prefix     = if ($Mode -eq 'Guide') { 'Scope25-Guide-Loi25' } else { 'Scope25-Audit-Loi25' }
        $fileName   = "$prefix-$safeTenant-$((Get-Date).ToString('yyyyMMdd-HHmmss')).html"
        $outPath    = Join-Path -Path $OutputDirectory -ChildPath $fileName

        if ($PSCmdlet.ShouldProcess($outPath, 'Write Loi 25 compliance report')) {
            # UTF-8 without BOM: some browsers render a stray glyph before <!DOCTYPE> otherwise.
            $enc = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($outPath, $html, $enc)

            Write-Scope25AuditLog -Action 'New-Scope25Report' -Outcome 'Success' `
                -Detail "Rapport généré : $outPath ($($summary.TotalControls) contrôles; $($summary.EvidenceCollected) preuves techniques recueillies; $($summary.EvidenceToObtain) a obtenir auprès de l'organisation)" | Out-Null

            Write-Verbose "Rapport écrit : $outPath"
            Write-Verbose "Journal opérationnel : $(Join-Path $logDir 'scope25-operations.log')"

            if ($PassThru) { $outPath }
        }
    }
}

function Get-Scope25DataMap {
    <#
    .SYNOPSIS
        Builds a high-level map of which categories of personal data sit in which workloads.
    .DESCRIPTION
        Answers the question a client actually asks first: "what kind of personal data do we hold,
        and where is it?" Aggregates Content Explorer counts per Scope25 category across SharePoint,
        OneDrive, Exchange and Teams.

        DELIBERATELY COARSE BY DEFAULT. Workload-level counts only - no site names, no mailboxes.
        Two reasons, and both matter more than they first appear:

        1. A document stating "health data lives in these three SharePoint sites" is a targeting map.
           It is the single most useful page an attacker could steal from a compliance engagement,
           and it lands in the Downloads folder.
        2. Exchange and Teams endpoint detail resolves to USER PRINCIPAL NAMES. A list of named
           employees whose mailboxes contain RAMQ numbers is itself a collection of personal
           information about those employees - and arguably sensitive, since it links named
           individuals to health data. Producing it to demonstrate Loi 25 compliance would create a
           new Loi 25 problem.

        -IncludeEndpoints therefore returns SharePoint and OneDrive site URLs ONLY. Mailbox and Teams
        UPNs are never enumerated by this cmdlet, by design and not by omission. If a client
        genuinely needs per-mailbox detail, that is a scoped investigation with its own authorization,
        not a line item in a standing compliance report.

        Read-only. Requires a Security & Compliance PowerShell session. Uses -Aggregate throughout,
        so the Content Explorer List Viewer role is sufficient - Content Viewer is not required and
        should not be requested for this.
    .PARAMETER IncludeEndpoints
        Also return SharePoint/OneDrive site URLs per category. Raises the sensitivity of the report;
        see the warning this switch emits.
    .PARAMETER TopEndpoints
        How many endpoints to keep per category. Default 5 - this is a high-level overview, not an
        inventory.
    .EXAMPLE
        Get-Scope25DataMap
    .EXAMPLE
        Get-Scope25DataMap -IncludeEndpoints -TopEndpoints 3
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][string]$TaxonomyPath = (Join-Path -Path (Join-Path -Path $Script:Scope25ModuleRoot -ChildPath 'Templates') -ChildPath 'Scope25_Labels.json'),
        [Parameter()][switch]$IncludeEndpoints,
        [Parameter()][ValidateRange(1,25)][int]$TopEndpoints = 5
    )

    if (-not (Test-Path -Path $TaxonomyPath)) { throw "Label definitions not found at '$TaxonomyPath'." }
    if (-not (Get-Command -Name 'Export-ContentExplorerData' -ErrorAction SilentlyContinue)) {
        throw 'Export-ContentExplorerData is not available. Connect to Security & Compliance PowerShell first (Connect-IPPSSession) with the Content Explorer List Viewer role.'
    }

    if ($IncludeEndpoints) {
        Write-Warning 'Endpoint names will be included. The resulting report identifies where the most sensitive data is concentrated - treat it as a confidential document and store it accordingly. Mailbox and Teams UPNs are never included.'
    }

    $taxonomy = Get-Content -Path $TaxonomyPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

    # Friendly labels; SPO/ODB are the only ones eligible for endpoint detail.
    $workloads = @(
        [pscustomobject]@{ Key = 'SharePoint'; Label = 'SharePoint'; SiteBased = $true  }
        [pscustomobject]@{ Key = 'OneDrive';   Label = 'OneDrive';   SiteBased = $true  }
        [pscustomobject]@{ Key = 'Exchange';   Label = 'Exchange';   SiteBased = $false }
        [pscustomobject]@{ Key = 'Teams';      Label = 'Teams';      SiteBased = $false }
    )

    foreach ($labelDef in $taxonomy.labels) {

        $total = 0
        $byWorkload = @()
        $endpoints  = @()

        foreach ($w in $workloads) {
            $count = 0
            try {
                $res = Export-ContentExplorerData -TagName $labelDef.name -TagType 'Sensitivity' `
                        -Workload $w.Key -Aggregate -ErrorAction Stop -WarningAction SilentlyContinue

                # Item 0 carries TotalCount; records start at index 1.
                $head = @($res)[0]
                if ($head -and $null -ne $head.TotalCount) { $count = [int]$head.TotalCount }

                if ($IncludeEndpoints -and $w.SiteBased -and $count -gt 0) {
                    foreach ($rec in @($res) | Select-Object -Skip 1) {
                        $name = $null
                        foreach ($prop in 'SiteUrl','Url','Location','FolderPath') {
                            if ($rec.PSObject.Properties.Name -contains $prop -and $rec.$prop) { $name = $rec.$prop; break }
                        }
                        if (-not $name) { continue }
                        $n = 0
                        if ($rec.PSObject.Properties.Name -contains 'TotalCount' -and $rec.TotalCount) { $n = [int]$rec.TotalCount }
                        $endpoints += [pscustomobject]@{ Type = "Site $($w.Label)"; Name = $name; ItemCount = $n }
                    }
                }
            } catch {
                Write-Verbose "Workload $($w.Key) unavailable for '$($labelDef.name)': $($_.Exception.Message)"
                $count = 0
            }

            if ($count -gt 0) {
                $byWorkload += [pscustomobject]@{ Workload = $w.Label; ItemCount = $count }
                $total += $count
            }
        }

        $topEp = @()
        if ($endpoints.Count -gt 0) {
            $topEp = @($endpoints | Sort-Object -Property ItemCount -Descending | Select-Object -First $TopEndpoints)
        }

        [pscustomobject]@{
            Category       = $labelDef.name
            DisplayFr      = $labelDef.displayNameFr
            DataTypesFr    = @($labelDef.dataTypesFr)
            TotalItems     = $total
            ByWorkload     = $byWorkload
            Endpoints      = $topEp
            EndpointDetail = [bool]$IncludeEndpoints
            Classification = $labelDef.caiGuidance.classificationFr
            CaiObligations = @($labelDef.caiGuidance.obligationsFr)
            CaiAction      = $labelDef.caiGuidance.actionFr
            ConfidenceNote = $labelDef.confidenceNote
        }
    }
}

function Get-Scope25SitDetection {
    <#
    .SYNOPSIS
        Counts detections per sensitive information type - the raw "what kinds of personal data
        are in here" picture, before any labelling.
    .DESCRIPTION
        Queries Content Explorer per SIT (TagType SensitiveInformationType) rather than per label.
        This matters in an incident: labels only exist where someone applied them, but SIT
        détections fire on content regardless. If nobody ever deployed labelling, label counts
        read as zero while the data is very much there. SIT counts see it anyway.

        Covers the Scope25 Quebec SITs plus the Microsoft built-ins for Canadian identifiers.
        Feeds the pie chart in the report.

        TIMING - THE MOST IMPORTANT CAVEAT IN THIS MODULE. This cmdlet is a QUERY, not a scan. It
        returns in seconds because it reads Purview's existing classification index. It never
        crawls anything.

        That speed is also the trap. Microsoft's own documentation states that when a sensitive
        information type definition is updated, the classification of existing files does not
        change unless those files are altered. So a custom SIT imported last week will not have
        retroactively classified a document that has sat untouched in SharePoint since 2023.
        Published field guidance puts detection in Content Explorer at roughly one to seven days
        after a reindex, and Microsoft has been rolling out an "unscanned files" metric precisely
        because this blind spot is common.

        The failure mode that matters: running this during an incident, seeing zero RAMQ numbers in
        a compromised site, and concluding no health data was exposed - when the real answer is
        that nothing there has been scanned since the SIT was imported. That mistake leads to not
        notifying the Commission d'acces a l'information. Import the SITs and confirm indexing well
        before you need the answer, and treat a zero as "not observed", never as "not present".

        Uses -Aggregate, so the Content Explorer List Viewer role is sufficient; Content Viewer
        is not needed and should not be requested for this.

        Only detectors anchored on a published structural format are included. The firearms-licence
        and recreational-permit detectors were removed rather than downgraded: no such format exists
        for either, so they would have fired mostly on coincidence, and in a report that claims to
        state observations rather than verdicts, a noisy detector discredits the accurate ones.
    .PARAMETER ConfidenceLevel
        Filter to a confidence level (High, Medium, Low). Omit for all matches. Every shipped
        detector is anchored on a published format, so High is a reasonable default when you want
        counts you can defend in a report; the wider levels are useful for triage.
    .EXAMPLE
        Get-Scope25SitDetection
    .EXAMPLE
        Get-Scope25SitDetection -ConfidenceLevel High
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][ValidateSet('High','Medium','Low')][string]$ConfidenceLevel,
        [Parameter()][string[]]$SitName
    )

    if (-not (Get-Command -Name 'Export-ContentExplorerData' -ErrorAction SilentlyContinue)) {
        throw 'Export-ContentExplorerData is not available. Connect to Security & Compliance PowerShell first (Connect-IPPSSession).'
    }

    Write-Warning ("Ces comptes proviennent de l'index de classification existant de Purview - ils ne declenchent " +
        "aucune analyse. Microsoft documente qu'une modification de definition de SIT ne reclasse PAS les fichiers " +
        "existants tant qu'ils ne sont pas modifies ou reindexes. Un SIT importe recemment peut donc afficher zero " +
        "alors que la donnee est bien presente. NE PAS conclure a l'absence de donnees sur cette base lors d'un incident.")

    # Category mapping mirrors Scope25_Labels.json so the pie chart can colour by category.
    $catalogue = @(
        @{ Name = 'Quebec RAMQ Health Insurance Number (NAM)';                  Cat = 'Santé';     Source = 'Scope25' }
        @{ Name = 'Canada Social Insurance Number';                             Cat = 'Identité';  Source = 'Microsoft' }
        @{ Name = "Canada Driver's License Number";                             Cat = 'Identité';  Source = 'Microsoft' }
        @{ Name = 'Canada Passport Number';                                     Cat = 'Identité';  Source = 'Microsoft' }
        @{ Name = 'Quebec Civil Status Document Number (NIREC)';                Cat = 'Identité';  Source = 'Scope25' }
        @{ Name = 'Credit Card Number';                                         Cat = 'Financier'; Source = 'Microsoft' }
        @{ Name = 'Canada Bank Account Number';                                 Cat = 'Financier'; Source = 'Microsoft' }
        @{ Name = 'Canada Cheque Transit and Institution Number (specimen cheque)'; Cat = 'Financier'; Source = 'Scope25' }
        @{ Name = 'Quebec Civic Address';                                       Cat = 'Adresse';   Source = 'Scope25' }
    )

    if ($SitName) { $catalogue = $catalogue | Where-Object { $SitName -contains $_.Name } }

    foreach ($sit in $catalogue) {
        $count = 0
        $state = 'Recueillie'
        try {
            $params = @{ TagName = $sit.Name; TagType = 'SensitiveInformationType'; Aggregate = $true; ErrorAction = 'Stop'; WarningAction = 'SilentlyContinue' }
            if ($ConfidenceLevel) { $params['ConfidenceLevel'] = $ConfidenceLevel }
            $res = Export-ContentExplorerData @params
            $head = @($res)[0]
            if ($head -and $null -ne $head.TotalCount) { $count = [int]$head.TotalCount }
        } catch {
            # A SIT that was never imported simply is not there - that is information, not an error.
            $state = 'Indisponible'
            Write-Verbose "SIT '$($sit.Name)' : $($_.Exception.Message)"
        }

        [pscustomobject]@{
            SitName    = $sit.Name
            Category   = $sit.Cat
            Source     = $sit.Source
            ItemCount  = $count
            Confidence = if ($ConfidenceLevel) { $ConfidenceLevel } else { 'Tous niveaux' }
            State      = $state
        }
    }
}

function Test-Scope25LogIntegrity {
    <#
    .SYNOPSIS
        Verifies the hash chain of the Scope25 operational log.
    .DESCRIPTION
        Each log entry stores the SHA256 hash of the previous line. Recomputing the chain shows
        whether any earlier entry was altered or removed after the fact: change one line and every
        subsequent link stops matching.

        Worth being precise about what this proves. It makes silent edits DETECTABLE, not
        impossible. Someone with write access and this cmdlet's source - which is to say anyone,
        since it ships readable - can rewrite the whole file and recompute every hash. This is
        tamper-evidence for accidents and casual edits, and it is genuinely useful in an
        after-action review. It is not a chain of custody. For evidence that has to survive an
        adversary or a courtroom, ship these entries to append-only storage or a SIEM as they
        are written.
    .EXAMPLE
        Test-Scope25LogIntegrity
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter()][string]$LogPath)

    if (-not $LogPath) {
        $dir = if ($env:ProgramData) { Join-Path $env:ProgramData 'Scope25.Purview\Logs' } else { Join-Path $HOME '.scope25-purview/logs' }
        $LogPath = Join-Path $dir 'scope25-operations.log'
    }
    if (-not (Test-Path -Path $LogPath)) { throw "Aucun journal trouvé a '$LogPath'." }

    $lines = @(Get-Content -Path $LogPath -ErrorAction Stop | Where-Object { $_.Trim() })
    $expected = '0' * 64
    $broken = @()

    for ($i = 0; $i -lt $lines.Count; $i++) {
        try { $entry = $lines[$i] | ConvertFrom-Json -ErrorAction Stop }
        catch { $broken += ($i + 1); continue }

        if ($entry.PreviousHash -ne $expected) { $broken += ($i + 1) }

        $sha = [System.Security.Cryptography.SHA256]::Create()
        $expected = ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($lines[$i])) | ForEach-Object { $_.ToString('x2') }) -join ''
        $sha.Dispose()
    }

    [pscustomobject]@{
        LogPath      = $LogPath
        EntryCount   = $lines.Count
        ChainIntact  = ($broken.Count -eq 0)
        BrokenAtLine = $broken
        Note         = if ($broken.Count -eq 0) {
            'Chaîne intacte : aucune entree antérieure ne semble avoir ete modifiée ou retirée.'
        } else {
            "Rupture de chaîne à la ou aux lignes : $($broken -join ', '). Une entree antérieure a ete modifiée, retirée ou insérée."
        }
    }
}

function Get-Scope25StatePath {
    <#
    .SYNOPSIS
        Internal helper. Path to the file recording when the detectors were deployed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $dir = if ($env:ProgramData) { Join-Path $env:ProgramData 'Scope25.Purview' } else { Join-Path $HOME '.scope25-purview' }
    if (-not (Test-Path -Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    Join-Path $dir 'setup-state.json'
}

function Invoke-Scope25Setup {
    <#
    .SYNOPSIS
        ÉTAPE 1 sur 2. Déploie les détecteurs et les étiquettes, puis produit le Guide Loi 25.
    .DESCRIPTION
        Première des deux exécutions. Cette étape configure le tenant et remet un document
        exploitable immédiatement - mais elle ne compte rien et n'affirme rien sur les données de
        l'organisation, parce qu'à cet instant précis Purview n'a encore rien classé selon les
        nouveaux détecteurs.

        C'est le point du découpage en deux temps. Un chiffre produit maintenant serait un zéro
        trompeur : Microsoft indique qu'une nouvelle définition de type d'information sensible ne
        reclasse pas les fichiers existants tant qu'ils ne sont pas modifiés ou réindexés. Plutôt
        que d'afficher un compte que personne ne devrait croire, cette étape n'en affiche aucun.

        Ce qu'elle fait :
          1. Importe les types d'information sensible propres au Québec.
          2. Crée et publie les quatre étiquettes de catégorie.
          3. Enregistre la date de déploiement, pour que l'étape 2 sache d'elle-même combien de
             temps l'indexation a eu.
          4. Génère le Guide Loi 25 : les 40 obligations du référentiel, leur fondement légal et
             les orientations de la Commission - sans aucune donnée du tenant.

        Le guide est utile dès le premier jour. Pendant que l'indexation se fait, l'organisation a
        déjà de quoi travailler sur les obligations organisationnelles, qui sont de toute façon la
        majorité et qu'aucun délai technique ne bloque.

        Prévoyez ensuite au moins sept jours avant Invoke-Scope25Audit. Voir la section
        « Vérifier que la classification a bien eu lieu » du README.
    .PARAMETER SkipDeployment
        Génère uniquement le guide, sans rien modifier dans le tenant. Utile pour produire le
        document de référence sans session Security & Compliance.
    .EXAMPLE
        Connect-IPPSSession -UserPrincipalName admin@contoso.onmicrosoft.com
        Invoke-Scope25Setup -WhatIf
    .EXAMPLE
        Invoke-Scope25Setup -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][string]$OutputDirectory,
        [Parameter()][string]$TenantLabel,
        [Parameter()][switch]$SkipDeployment
    )

    $steps = [System.Collections.Generic.List[psobject]]::new()

    if (-not $SkipDeployment) {
        try {
            $sit = Import-Scope25QuebecSIT -ErrorAction Stop
            $steps.Add([pscustomobject]@{ Step = 'Types d''information sensible'; Result = 'Importés'; Detail = ($sit.SourceFile) })
        } catch {
            $steps.Add([pscustomobject]@{ Step = 'Types d''information sensible'; Result = 'Échec'; Detail = $_.Exception.Message })
            Write-Warning "Importation des SIT : $($_.Exception.Message)"
        }
        try {
            $lab = @(Publish-Scope25SensitivityLabels -ErrorAction Stop)
            $created = @($lab | Where-Object { $_.Action -eq 'Created' }).Count
            $steps.Add([pscustomobject]@{ Step = 'Étiquettes de catégorie'; Result = 'Publiées'; Detail = "$created créée(s) sur $($lab.Count)" })
        } catch {
            $steps.Add([pscustomobject]@{ Step = 'Étiquettes de catégorie'; Result = 'Échec'; Detail = $_.Exception.Message })
            Write-Warning "Publication des étiquettes : $($_.Exception.Message)"
        }
    } else {
        $steps.Add([pscustomobject]@{ Step = 'Déploiement'; Result = 'Ignoré'; Detail = '-SkipDeployment' })
    }

    # Remember the deployment date so step 2 does not have to be told.
    $tenant = $TenantLabel
    if (-not $tenant -and (Get-Command 'Get-MgContext' -ErrorAction SilentlyContinue)) {
        $ctx = Get-MgContext
        if ($ctx) { $tenant = $ctx.TenantId }
    }
    if (-not $tenant) { $tenant = 'n/d' }

    $statePath = Get-Scope25StatePath
    if ($PSCmdlet.ShouldProcess($statePath, 'Enregistrer la date de déploiement')) {
        [ordered]@{
            setupDateUtc   = (Get-Date).ToUniversalTime().ToString('o')
            tenant         = $tenant
            moduleVersion  = $Script:Scope25Version
            deployed       = (-not $SkipDeployment)
        } | ConvertTo-Json | Set-Content -Path $statePath -Encoding UTF8
    }

    # Guide: the framework and the law, with nothing from the tenant in it.
    $assessment = Invoke-Scope25Loi25Assessment -SkipAuditLog -GuideOnly
    $guidePath = $assessment | New-Scope25Report -Mode Guide -TenantLabel $tenant `
                    -OutputDirectory $OutputDirectory -PassThru

    Write-Scope25AuditLog -Action 'Invoke-Scope25Setup' -Outcome 'Success' `
        -Detail "Étape 1 terminée. Guide : $guidePath" | Out-Null

    [pscustomobject]@{
        Phase        = 'Étape 1 sur 2 - Déploiement et guide'
        Steps        = $steps
        GuidePath    = $guidePath
        StatePath    = $statePath
        NextStep     = 'Laissez Purview indexer le contenu, puis exécutez Invoke-Scope25Audit. Prévoyez au moins sept jours. Vérifiez la couverture de classification dans le portail Purview avant de vous fier aux chiffres - voir le README.'
    }
}

function Invoke-Scope25Audit {
    <#
    .SYNOPSIS
        ÉTAPE 2 sur 2. Produit le rapport d'audit complet : inventaire, emplacements, camembert.
    .DESCRIPTION
        Seconde exécution, à faire une fois que Purview a eu le temps d'indexer le contenu selon
        les détecteurs déployés à l'étape 1.

        Elle lit la date de déploiement enregistrée par Invoke-Scope25Setup et vous avertit
        d'elle-même si le délai est trop court. L'avertissement n'est pas bloquant : il existe de
        bonnes raisons de vouloir un instantané précoce. Mais un rapport produit trois jours après
        le déploiement décrit surtout ce que Purview a eu le temps de voir, pas ce que
        l'organisation détient.

        Rassemble : détections par type d'information sensible, cartographie par charge de travail,
        et les constats techniques rattachés aux 40 obligations du référentiel.
    .PARAMETER IncludeEndpoints
        Inclut les noms de sites SharePoint/OneDrive. Rend le rapport nettement plus sensible :
        il devient une carte des emplacements les plus convoités. Les boîtes aux lettres nominatives
        ne sont jamais énumérées.
    .PARAMETER Force
        Génère le rapport sans demander confirmation si le délai depuis le déploiement est court.
    .EXAMPLE
        Connect-Scope25Tenant
        Connect-IPPSSession -UserPrincipalName admin@contoso.onmicrosoft.com
        Invoke-Scope25Audit
    .EXAMPLE
        Invoke-Scope25Audit -IncludeEndpoints
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][string]$OutputDirectory,
        [Parameter()][string]$TenantLabel,
        [Parameter()][switch]$IncludeEndpoints,
        [Parameter()][switch]$Force
    )

    # How long has the environment actually had to index?
    $setupDate = $null
    $statePath = Get-Scope25StatePath
    if (Test-Path -Path $statePath) {
        try {
            $state = Get-Content -Path $statePath -Raw | ConvertFrom-Json
            $setupDate = [datetime]$state.setupDateUtc
        } catch {
            Write-Verbose "État de déploiement illisible : $($_.Exception.Message)"
        }
    }

    if ($setupDate) {
        $days = [int]((Get-Date).ToUniversalTime() - $setupDate).TotalDays
        if ($days -lt 7) {
            $msg = "Les détecteurs ont été déployés il y a $days jour(s). Microsoft n'applique pas " +
                   "rétroactivement un nouveau type d'information sensible aux fichiers existants tant " +
                   "qu'ils ne sont pas modifiés ou réindexés, et l'apparition des résultats prend " +
                   "couramment de un à sept jours. Les comptes de ce rapport seront un plancher, pas un " +
                   "inventaire : un zéro voudra dire « rien d'observé », jamais « rien de présent »."
            Write-Warning $msg
            if (-not $Force) {
                $reponse = Read-Host "Générer quand même le rapport ? (o/N)"
                if ($reponse -notmatch '^(o|oui|y|yes)$') {
                    Write-Host "Annulé. Relancez Invoke-Scope25Audit plus tard, ou utilisez -Force." -ForegroundColor Yellow
                    return
                }
            }
        }
    } else {
        Write-Warning "Aucune date de déploiement trouvée : Invoke-Scope25Setup n'a pas été exécuté sur ce poste, ou l'état a été supprimé. Le rapport ne pourra pas situer l'ancienneté de l'indexation."
    }

    Write-Verbose 'Collecte des détections par type d''information sensible...'
    $sits = @(Get-Scope25SitDetection -ErrorAction SilentlyContinue)

    Write-Verbose 'Cartographie par charge de travail...'
    $mapParams = @{ ErrorAction = 'SilentlyContinue' }
    if ($IncludeEndpoints) { $mapParams['IncludeEndpoints'] = $true }
    $map = @(Get-Scope25DataMap @mapParams)

    Write-Verbose 'Collecte des constats techniques par contrôle...'
    $assessment = Invoke-Scope25Loi25Assessment -SkipAuditLog

    $reportParams = @{ Mode = 'Audit'; DataMap = $map; SitDetection = $sits; PassThru = $true }
    if ($OutputDirectory) { $reportParams['OutputDirectory'] = $OutputDirectory }
    if ($TenantLabel)     { $reportParams['TenantLabel'] = $TenantLabel }
    if ($setupDate)       { $reportParams['SitsImportedOn'] = $setupDate.ToLocalTime() }

    $path = $assessment | New-Scope25Report @reportParams

    Write-Scope25AuditLog -Action 'Invoke-Scope25Audit' -Outcome 'Success' `
        -Detail "Étape 2 terminée. Rapport : $path" | Out-Null

    [pscustomobject]@{
        Phase          = 'Étape 2 sur 2 - Rapport d''audit'
        ReportPath     = $path
        SitsDetected   = @($sits | Where-Object { $_.ItemCount -gt 0 }).Count
        TotalItems     = (($sits | Measure-Object -Property ItemCount -Sum).Sum)
        DeployedOn     = if ($setupDate) { $setupDate.ToLocalTime().ToString('yyyy-MM-dd') } else { 'inconnu' }
        EndpointDetail = [bool]$IncludeEndpoints
    }
}

function Test-Scope25SitPattern {
    <#
    .SYNOPSIS
        Vérifie hors ligne que chaque motif de détection se déclenche là où il doit, et nulle part ailleurs.
    .DESCRIPTION
        Lit les expressions régulières directement dans Templates/Quebec_SITs.xml et les exécute contre
        les vecteurs de Templates/Scope25_SitTests.json. Aucune connexion, aucun tenant, aucune donnée
        réelle.

        Les motifs sont lus dans le XML plutôt que recopiés ici, exprès : si quelqu'un modifie une
        expression et oublie d'ajuster les tests, ce banc d'essai le signale au lieu de valider une
        copie périmée.

        Les cas négatifs comptent autant que les positifs. Un détecteur qui attrape tout n'attrape rien
        d'utile : dans un rapport de conformité, un faux positif gonfle les comptes et discrédite les
        détections justes. C'est pourquoi chaque motif est testé contre des valeurs qui lui ressemblent
        sans en être - un code postal de Toronto, un mois de naissance impossible, un code d'institution
        bancaire inexistant.

        PORTÉE - à ne pas surestimer. Ce banc valide la logique des expressions avec le moteur .NET. Il
        ne reproduit ni le moteur de Microsoft Purview, ni ses règles de proximité, ni la corroboration
        par mots-clés. Un motif qui passe ici reste à confirmer dans un tenant réel avec
        Test-DataClassification. Ce qu'il garantit, c'est qu'une modification d'expression ne casse pas
        silencieusement une détection.
    .PARAMETER Detailed
        Affiche chaque cas plutôt qu'un sommaire par motif.
    .EXAMPLE
        Test-Scope25SitPattern
    .EXAMPLE
        Test-Scope25SitPattern -Detailed
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][string]$SitPath   = (Join-Path -Path (Join-Path -Path $Script:Scope25ModuleRoot -ChildPath 'Templates') -ChildPath 'Quebec_SITs.xml'),
        [Parameter()][string]$TestPath  = (Join-Path -Path (Join-Path -Path $Script:Scope25ModuleRoot -ChildPath 'Templates') -ChildPath 'Scope25_SitTests.json'),
        [Parameter()][switch]$Detailed
    )

    if (-not (Test-Path -Path $SitPath))  { throw "Fichier de motifs introuvable : '$SitPath'." }
    if (-not (Test-Path -Path $TestPath)) { throw "Vecteurs de test introuvables : '$TestPath'." }

    [xml]$sitXml = Get-Content -Path $SitPath -Raw -ErrorAction Stop
    $suite = Get-Content -Path $TestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

    # Index the patterns actually present in the rule package.
    $patterns = @{}
    foreach ($node in $sitXml.GetElementsByTagName('Regex')) {
        $patterns[$node.id] = $node.InnerText
    }

    foreach ($test in $suite.tests) {

        if (-not $patterns.ContainsKey($test.regexId)) {
            # The pattern named by the test no longer exists - usually an entity was removed
            # without pruning its vectors, which would otherwise pass unnoticed.
            [pscustomobject]@{
                Motif = $test.label; RegexId = $test.regexId; Reussis = 0; Echecs = 0
                Statut = 'MOTIF ABSENT'
                Detail = "Aucune expression '$($test.regexId)' dans $([IO.Path]::GetFileName($SitPath)). Vecteur orphelin à retirer, ou entité supprimée par erreur."
            }
            continue
        }

        $rx = [regex]$patterns[$test.regexId]
        $pass = 0; $failures = [System.Collections.Generic.List[string]]::new()

        foreach ($case in $test.positifs) {
            if ($rx.IsMatch($case.valeur)) { $pass++ }
            else { $failures.Add("devrait correspondre mais ne correspond pas : '$($case.valeur)' ($($case.note))") }
            if ($Detailed) {
                $ok = $rx.IsMatch($case.valeur)
                Write-Host ("    {0}  positif  {1,-18} {2}" -f $(if($ok){'ok  '}else{'ECHEC'}), $case.valeur, $case.note) `
                    -ForegroundColor $(if($ok){'Green'}else{'Red'})
            }
        }

        foreach ($case in $test.negatifs) {
            if (-not $rx.IsMatch($case.valeur)) { $pass++ }
            else { $failures.Add("ne devrait PAS correspondre mais correspond : '$($case.valeur)' ($($case.note))") }
            if ($Detailed) {
                $ok = -not $rx.IsMatch($case.valeur)
                Write-Host ("    {0}  negatif  {1,-18} {2}" -f $(if($ok){'ok  '}else{'ECHEC'}), $case.valeur, $case.note) `
                    -ForegroundColor $(if($ok){'Green'}else{'Red'})
            }
        }

        [pscustomobject]@{
            Motif   = $test.label
            RegexId = $test.regexId
            Reussis = $pass
            Echecs  = $failures.Count
            Statut  = if ($failures.Count -eq 0) { 'OK' } else { 'ÉCHEC' }
            Detail  = if ($failures.Count -eq 0) { "$pass cas vérifiés" } else { $failures -join ' | ' }
        }
    }

    # Catch the reverse drift too: a pattern in the rule package with no test coverage.
    $tested = @($suite.tests | ForEach-Object { $_.regexId })
    foreach ($id in $patterns.Keys) {
        if ($id -notin $tested) {
            [pscustomobject]@{
                Motif = '(non couvert)'; RegexId = $id; Reussis = 0; Echecs = 0
                Statut = 'SANS TEST'
                Detail = "Cette expression existe dans le paquet de règles mais aucun vecteur ne la couvre. Ajoutez des cas dans $([IO.Path]::GetFileName($TestPath))."
            }
        }
    }
}

Export-ModuleMember -Function 'Get-Scope25ModuleInfo', 'Test-Scope25Prerequisites', 'Connect-Scope25Tenant', 'Disconnect-Scope25Tenant', 'Get-Scope25ConnectionInfo', 'Get-Scope25DelegatedTenant', 'Invoke-Scope25Setup', 'Invoke-Scope25Audit', 'Import-Scope25QuebecSIT', 'Publish-Scope25SensitivityLabels', 'Get-Scope25LabelCoverage', 'Get-Scope25DataMap', 'Get-Scope25SitDetection', 'Test-Scope25SitPattern', 'Write-Scope25AuditLog', 'Test-Scope25LogIntegrity', 'Invoke-Scope25Loi25Assessment', 'Get-Scope25AssessmentSummary', 'New-Scope25Report'
