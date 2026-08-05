#
# Module manifest for module 'Scope25.Purview'
#
# Logiciel libre sous licence Apache 2.0.
#
# NOTE: Author / CompanyName / Copyright below are placeholders. Fill them in, and match
# the copyright holder named in LICENSE.txt.
#

@{
    RootModule            = 'Scope25.Purview.psm1'


    ModuleVersion         = '1.6.0'
    GUID                  = 'f62b0424-9c86-4e66-bfc3-150eb65e6116'

    Author                = '[Nom de l''auteur / Author name]'
    CompanyName           = '[Raison sociale à définir / Company name TBD]'
    Copyright             = '(c) 2026 [Titulaire du droit d''auteur]. Sous licence Apache 2.0. Licensed under the Apache License 2.0.'

    Description           = 'Outil libre d''audit forensique des renseignements personnels dans Microsoft 365, aligne sur la Loi 25 (Quebec). Recense quelles donnees personnelles existent et ou, avant ou apres un incident. Ne rend aucun verdict de conformite. Open-source forensic data auditing for Microsoft 365, aligned to Quebec Law 25.'

    PowerShellVersion     = '5.1'
    CompatiblePSEditions  = @('Desktop', 'Core')

    # DELIBERATELY EMPTY. These modules were previously declared here, and testing on a clean
    # machine showed why that was wrong: PowerShell enforces RequiredModules at import time, so
    # anyone without Microsoft.Graph.Authentication, Microsoft.Graph.Identity.Partner and
    # ExchangeOnlineManagement installed could not import Scope25.Purview at all - not even to
    # read the guide or run the diagnostics, which need none of them.
    #
    # Dependencies are checked at the point of use instead. Every cmdlet that needs Graph or
    # Security & Compliance PowerShell verifies the cmdlet is present and fails with a message
    # naming exactly what to install. That turns a hard block at import into a clear instruction
    # at the moment it matters.
    RequiredModules       = @()

    FunctionsToExport     = @(
        'Get-Scope25ModuleInfo',
        'Test-Scope25Prerequisites',
        'Connect-Scope25Tenant',
        'Disconnect-Scope25Tenant',
        'Get-Scope25ConnectionInfo',
        'Get-Scope25DelegatedTenant',
        'Invoke-Scope25Setup',
        'Invoke-Scope25Audit',
        'Import-Scope25QuebecSIT',
        'Publish-Scope25SensitivityLabels',
        'Get-Scope25LabelCoverage',
        'Get-Scope25DataMap',
        'Get-Scope25SitDetection',
        'Test-Scope25SitPattern',
        'Write-Scope25AuditLog',
        'Test-Scope25LogIntegrity',
        'Invoke-Scope25Loi25Assessment',
        'Get-Scope25AssessmentSummary',
        'New-Scope25Report'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Loi25', 'Forensics', 'IncidentResponse', 'DFIR', 'OpenSource', 'Quebec', 'Purview', 'MicrosoftGraph', 'GDAP', 'Compliance', 'MSSP', 'Audit', 'CAI', 'PrivacyLaw')
            LicenseUri   = 'https://www.apache.org/licenses/LICENSE-2.0'
            ProjectUri   = ''
            ReleaseNotes = '1.6.0 : corrige deux plantages introduits par le retrait de RequiredModules - Get-Scope25ConnectionInfo et Disconnect-Scope25Tenant appelaient Get-MgContext sans verifier sa presence, alors que le module s importe volontairement sans Microsoft.Graph. Traduit les constats de sonde qui apparaissaient en anglais dans le rapport client. Ajoute des tests de degradation sans session, un .gitignore qui empeche de commiter un rapport ou un journal, SECURITY.md et CONTRIBUTING.md.'
        }
    }
}
