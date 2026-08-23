[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [string] $PackagePath,

    [Parameter(Mandatory = $true)]
    [string] $SetupFilePath,

    [Parameter(Mandatory = $true)]
    [string] $DetectionScriptPath,

    [Parameter(Mandatory = $true)]
    [string] $DisplayName,

    [Parameter(Mandatory = $true)]
    [string] $Description,

    [Parameter(Mandatory = $true)]
    [string] $Publisher,

    [Parameter(Mandatory = $true)]
    [string] $InstallCommandLine,

    [Parameter(Mandatory = $true)]
    [string] $UninstallCommandLine,

    [ValidateSet('x86', 'x64', 'arm64')]
    [string] $Architecture = 'x64',

    # Install context for the app. Use 'user' for installers that only support
    # per-user installs (e.g. electron-builder one-click NSIS that ignores /ALLUSERS).
    [ValidateSet('system', 'user')]
    [string] $InstallRunAsAccount = 'system',

    # Intune's standard Win32 table includes 1707=success. Use Strict when the
    # wrapper owns exit-code validation and must not allow 1707 to bypass it.
    [ValidateSet('Default', 'Strict')]
    [string] $ReturnCodeProfile = 'Default',

    # Preserve is the non-mutating default for existing apps. Disable removes
    # the Company Portal uninstall action without changing assignments.
    [ValidateSet('Preserve', 'Enable', 'Disable')]
    [string] $AvailableUninstallPolicy = 'Preserve',

    # Rename the app during an UpdateExisting activation. -DisplayName must still
    # match the app's CURRENT name (identity check); this is the name it becomes.
    [string] $NewDisplayName,

    [string] $LogoPath,

    [string] $InformationUrl,

    [string] $PrivacyInformationUrl,

    [string] $Owner = 'Contoso IT',

    [string] $Developer,

    [string] $Notes,

    [string] $Version,

    [ValidateSet('CreateSeparateTest', 'UpdateExisting')]
    [string] $DeploymentIntent = 'CreateSeparateTest',

    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $ExistingAppId,

    [ValidatePattern('^[0-9]+$')]
    [string] $ActivateContentVersionId,

    [string] $Justification = 'Publish a Win32 app to Intune. No assignments are included.',

    [string] $SummaryPath,

    [ValidateSet('v1.0', 'beta')]
    [string] $GraphApiVersion = 'v1.0',

    [switch] $ReuseUnpublishedDraft,

    # Force the old delegated z_admin path. The default is app-only (App B,
    # "Contoso EUC Automation - Intune Write"), which survives the nightly z-account
    # password rotation. Use this only when a request must be filed as a human.
    [switch] $DelegatedGraph
)

$ErrorActionPreference = 'Stop'
$planningOnly = [bool] $WhatIfPreference
if ($planningOnly) {
    # We still need to unpack the local package and emit its summary during a dry run.
    $WhatIfPreference = $false
}

function ConvertTo-Base64Utf8 {
    param([Parameter(Mandatory = $true)][string] $Value)

    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
}

function Get-GraphErrorText {
    param([Parameter(Mandatory = $true)] $ErrorRecord)

    return @(
        $ErrorRecord.Exception.Message,
        $ErrorRecord.ErrorDetails.Message
    ) -join "`n"
}

function Get-ApprovalCodeFromError {
    param([Parameter(Mandatory = $true)] $ErrorRecord)

    foreach ($headerName in @('x-msft-approval-code', 'X-Msft-Approval-Code')) {
        try {
            $value = $ErrorRecord.Exception.ResponseHeaders[$headerName]
            if ($value) {
                return @($value)[0]
            }
        }
        catch {
        }
    }

    $text = Get-GraphErrorText -ErrorRecord $ErrorRecord

    if ($text -match 'x-msft-approval-code[:\s]+([0-9a-fA-F-]{36})') {
        return $matches[1]
    }

    if ($text -match 'ApprovalRequired' -and $text -match '([0-9a-fA-F-]{36})') {
        return $matches[1]
    }

    return $null
}

function Test-ActiveMaaConflict {
    param([Parameter(Mandatory = $true)] $ErrorRecord)

    return (Get-GraphErrorText -ErrorRecord $ErrorRecord) -match 'An active Approval Request already exists'
}

function Invoke-GraphJson {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')]
        [string] $Method,

        [Parameter(Mandatory = $true)]
        [string] $Uri,

        [object] $Body,

        [switch] $UseMaaJustification
    )

    $headers = @{}
    if ($UseMaaJustification) {
        $headers['x-msft-approval-justification'] = ConvertTo-Base64Utf8 -Value $Justification
    }

    $params = @{
        Method = $Method
        Uri = $Uri
        OutputType = 'PSObject'
        ErrorAction = 'Stop'
    }

    if ($headers.Count -gt 0) {
        $params.Headers = $headers
    }

    if ($PSBoundParameters.ContainsKey('Body')) {
        $params.Body = $Body | ConvertTo-Json -Depth 64
        $params.ContentType = 'application/json'
    }

    try {
        return Invoke-MgGraphRequest @params
    }
    catch {
        $approvalCode = Get-ApprovalCodeFromError -ErrorRecord $_
        if ($approvalCode) {
            $script:MaaApproval = [pscustomobject]@{
                requestId = $approvalCode
                method = $Method
                uri = $Uri
                status = $null
                message = $_.Exception.Message
            }
            throw "MAA approval required. Request ID: $approvalCode"
        }

        if (Test-ActiveMaaConflict -ErrorRecord $_) {
            $script:MaaApproval = [pscustomobject]@{
                requestId = $null
                method = $Method
                uri = $Uri
                status = 'needsApproval'
                message = $_.Exception.Message
                existingRequest = $true
            }
            throw 'MAA approval required. An active approval request already exists for this app.'
        }

        throw
    }
}

function Get-AllGraphPages {
    param([Parameter(Mandatory = $true)][string] $Uri)

    $items = New-Object System.Collections.Generic.List[object]
    $next = $Uri
    while ($next) {
        $response = Invoke-GraphJson -Method GET -Uri $next
        foreach ($item in @($response.value)) {
            $items.Add($item) | Out-Null
        }
        $next = $response.'@odata.nextLink'
    }

    return @($items.ToArray())
}

function Get-IntuneWinPackageInfo {
    param([Parameter(Mandatory = $true)][string] $Path)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $detectionEntry = $zip.GetEntry('IntuneWinPackage/Metadata/Detection.xml')
        if (-not $detectionEntry) {
            throw 'Detection.xml was not found inside the .intunewin package.'
        }

        $reader = [IO.StreamReader]::new($detectionEntry.Open())
        try {
            [xml] $detectionXml = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }

        $contentEntry = $zip.GetEntry('IntuneWinPackage/Contents/IntunePackage.intunewin')
        if (-not $contentEntry) {
            throw 'IntuneWinPackage/Contents/IntunePackage.intunewin was not found inside the .intunewin package.'
        }

        $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("intunewin-upload-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $encryptedPayloadPath = Join-Path $tempDir ([string] $detectionXml.ApplicationInfo.FileName)

        $source = $contentEntry.Open()
        try {
            $destination = [IO.File]::Open($encryptedPayloadPath, [IO.FileMode]::CreateNew)
            try {
                $source.CopyTo($destination)
            }
            finally {
                $destination.Dispose()
            }
        }
        finally {
            $source.Dispose()
        }

        return [pscustomobject]@{
            TempDir = $tempDir
            EncryptedPayloadPath = $encryptedPayloadPath
            EncryptedSize = (Get-Item -LiteralPath $encryptedPayloadPath).Length
            UnencryptedSize = [int64] $detectionXml.ApplicationInfo.UnencryptedContentSize
            FileName = [string] $detectionXml.ApplicationInfo.FileName
            SetupFile = [string] $detectionXml.ApplicationInfo.SetupFile
            EncryptionInfo = [ordered]@{
                encryptionKey = [string] $detectionXml.ApplicationInfo.EncryptionInfo.EncryptionKey
                macKey = [string] $detectionXml.ApplicationInfo.EncryptionInfo.MacKey
                initializationVector = [string] $detectionXml.ApplicationInfo.EncryptionInfo.InitializationVector
                mac = [string] $detectionXml.ApplicationInfo.EncryptionInfo.Mac
                profileIdentifier = [string] $detectionXml.ApplicationInfo.EncryptionInfo.ProfileIdentifier
                fileDigest = [string] $detectionXml.ApplicationInfo.EncryptionInfo.FileDigest
                fileDigestAlgorithm = [string] $detectionXml.ApplicationInfo.EncryptionInfo.FileDigestAlgorithm
            }
        }
    }
    finally {
        $zip.Dispose()
    }
}

function Get-PngIconPayload {
    param([Parameter(Mandatory = $true)][string] $Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $signature = [byte[]] (10014, 80, 78, 71, 13, 10, 26, 10)
    $hasPngSignature = $bytes.Length -ge 24
    for ($index = 0; $hasPngSignature -and $index -lt $signature.Length; $index++) {
        $hasPngSignature = $bytes[$index] -eq $signature[$index]
    }
    if (-not $hasPngSignature) {
        throw "Company Portal icon is not a valid PNG: $Path"
    }

    $width = ([int64] $bytes[16] * 16777216) + ([int64] $bytes[17] * 65536) + ([int64] $bytes[18] * 256) + [int64] $bytes[19]
    $height = ([int64] $bytes[20] * 16777216) + ([int64] $bytes[21] * 65536) + ([int64] $bytes[22] * 256) + [int64] $bytes[23]
    if ($width -lt 1 -or $height -lt 1 -or $width -ne $height) {
        throw "Company Portal icon must be a non-empty square PNG. Found ${width}x${height}: $Path"
    }

    return [ordered]@{
        '@odata.type' = '#microsoft.graph.mimeContent'
        type = 'image/png'
        value = [Convert]::ToBase64String($bytes)
    }
}

function Add-AzureStorageQuery {
    param(
        [Parameter(Mandatory = $true)][string] $StorageUri,
        [Parameter(Mandatory = $true)][hashtable] $Parameters
    )

    $query = foreach ($key in $Parameters.Keys) {
        '{0}={1}' -f [uri]::EscapeDataString($key), [uri]::EscapeDataString([string] $Parameters[$key])
    }
    $separator = if ($StorageUri.Contains('?')) { '&' } else { '?' }
    return "$StorageUri$separator$($query -join '&')"
}

function Invoke-AzureStorageBlobUpload {
    param(
        [Parameter(Mandatory = $true)][string] $StorageUri,
        [Parameter(Mandatory = $true)][string] $FilePath
    )

    if (-not ('System.Net.Http.HttpClient' -as [type])) {
        Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
    }

    $chunkSize = 6MB
    $buffer = New-Object byte[] $chunkSize
    $stream = [IO.File]::Open($FilePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $client = [Net.Http.HttpClient]::new()
    $blockIds = New-Object System.Collections.Generic.List[string]

    try {
        $blockIndex = 0
        while ($true) {
            $bytesRead = $stream.Read($buffer, 0, $buffer.Length)
            if ($bytesRead -le 0) {
                break
            }

            $blockId = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($blockIndex.ToString('D6')))
            $blockUri = Add-AzureStorageQuery -StorageUri $StorageUri -Parameters @{ comp = 'block'; blockid = $blockId }
            $content = [Net.Http.ByteArrayContent]::new($buffer, 0, $bytesRead)
            $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Put, $blockUri)
            $request.Content = $content
            $request.Headers.TryAddWithoutValidation('x-ms-blob-type', 'BlockBlob') | Out-Null
            $response = $null

            try {
                $response = $client.SendAsync($request).GetAwaiter().GetResult()
                if (-not $response.IsSuccessStatusCode) {
                    throw "Azure block upload failed with HTTP $([int] $response.StatusCode)."
                }
            }
            finally {
                if ($response) { $response.Dispose() }
                $request.Dispose()
                $content.Dispose()
            }

            $blockIds.Add($blockId) | Out-Null
            $blockIndex++
        }

        if ($blockIds.Count -eq 0) {
            throw 'The encrypted Intune payload was empty.'
        }

        $blockListXml = '<?xml version="1.0" encoding="utf-8"?><BlockList>'
        foreach ($blockId in $blockIds) {
            $blockListXml += "<Latest>$blockId</Latest>"
        }
        $blockListXml += '</BlockList>'

        $blockListUri = Add-AzureStorageQuery -StorageUri $StorageUri -Parameters @{ comp = 'blocklist' }
        $content = [Net.Http.StringContent]::new($blockListXml, [Text.Encoding]::UTF8, 'application/xml')
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Put, $blockListUri)
        $request.Content = $content
        $response = $null

        try {
            $response = $client.SendAsync($request).GetAwaiter().GetResult()
            if (-not $response.IsSuccessStatusCode) {
                throw "Azure block list commit failed with HTTP $([int] $response.StatusCode)."
            }
        }
        finally {
            if ($response) { $response.Dispose() }
            $request.Dispose()
            $content.Dispose()
        }

        Write-Host "Uploaded $($blockIds.Count) encrypted content blocks."
    }
    finally {
        $stream.Dispose()
        $client.Dispose()
    }
}

function Wait-MobileAppContentFile {
    param(
        [Parameter(Mandatory = $true)][string] $AppId,
        [Parameter(Mandatory = $true)][string] $ContentVersionId,
        [Parameter(Mandatory = $true)][string] $FileId,
        [Parameter(Mandatory = $true)][string[]] $SuccessStates,
        [Parameter(Mandatory = $true)][string[]] $FailureStates,
        [int] $TimeoutSeconds = 900
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $fileUri = "$script:GraphBase/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp/contentVersions/$ContentVersionId/files/$FileId"
    do {
        $file = Invoke-GraphJson -Method GET -Uri $fileUri
        $script:LastContentFile = $file
        Write-Host "Content file upload state: $($file.uploadState)"

        if ($file.uploadState -in $SuccessStates) {
            return $file
        }
        if ($file.uploadState -in $FailureStates) {
            throw "Content file entered failure state: $($file.uploadState)"
        }

        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for content file state: $($SuccessStates -join ', ')."
}

function Wait-MobileAppPublished {
    param(
        [Parameter(Mandatory = $true)][string] $AppId,
        [int] $TimeoutSeconds = 900
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $app = Invoke-GraphJson -Method GET -Uri "$script:GraphBase/deviceAppManagement/mobileApps/$AppId"
        Write-Host "App publishing state: $($app.publishingState)"
        if ($app.publishingState -eq 'published') {
            return $app
        }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)

    throw 'Timed out waiting for the Win32 app to publish.'
}

function Get-MaaRequestStatus {
    param([Parameter(Mandatory = $true)][string] $RequestId)

    try {
        $request = Invoke-GraphJson -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/operationApprovalRequests/$RequestId"
        if ($request) {
            return $request
        }
    }
    catch {
    }

    $filter = [uri]::EscapeDataString("requestId eq '$RequestId'")
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            $response = Invoke-GraphJson -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/operationApprovalRequests?`$filter=$filter"
            $request = @($response.value) | Select-Object -First 1
            if ($request) {
                return $request
            }
        }
        catch {
        }
        Start-Sleep -Seconds 3
    }

    return $null
}

function Get-ActiveMaaRequestForResource {
    param([Parameter(Mandatory = $true)][string] $TargetResourceId)

    $filter = [uri]::EscapeDataString("status eq 'needsApproval'")
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            $response = Invoke-GraphJson -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/operationApprovalRequests?`$filter=$filter"
            $request = @($response.value | Where-Object { $_.payloadId -eq $TargetResourceId }) | Select-Object -First 1
            if ($request) {
                return $request
            }
        }
        catch {
        }
        Start-Sleep -Seconds 3
    }

    return $null
}

function Write-Summary {
    param(
        [Parameter(Mandatory = $true)][string] $Status,
        [object] $App,
        [object] $Approval,
        [string] $ErrorMessage
    )

    $summaryDirectory = Split-Path -Parent $SummaryPath
    if ($summaryDirectory) {
        New-Item -ItemType Directory -Path $summaryDirectory -Force | Out-Null
    }

    [pscustomobject]@{
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        status = $Status
        operation = if ($DeploymentIntent -eq 'UpdateExisting') { 'updateExisting' } else { 'createSeparateTest' }
        deploymentIntent = $DeploymentIntent
        displayName = if ($NewDisplayName) { $NewDisplayName } else { $DisplayName }
        version = $Version
        appId = if ($App) { $App.id } else { $null }
        existingAppId = $ExistingAppId
        publishingState = if ($App) { $App.publishingState } else { $null }
        committedContentVersion = if ($App) { $App.committedContentVersion } else { $null }
        contentVersionId = if ($contentVersion) { $contentVersion.id } else { $null }
        contentFileId = if ($script:LastContentFile) { $script:LastContentFile.id } else { $null }
        contentFileUploadState = if ($script:LastContentFile) { $script:LastContentFile.uploadState } else { $null }
        packagePath = $PackagePath
        setupFilePath = $SetupFilePath
        detectionScriptPath = $DetectionScriptPath
        installCommandLine = $InstallCommandLine
        uninstallCommandLine = $UninstallCommandLine
        returnCodeProfile = $ReturnCodeProfile
        availableUninstallPolicy = $AvailableUninstallPolicy
        installExperiencePatched = ($DeploymentIntent -eq 'CreateSeparateTest')
        logoPath = $LogoPath
        assignmentsCreated = $false
        approval = $Approval
        error = $ErrorMessage
    } | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $SummaryPath -Encoding UTF8
}

foreach ($path in @($PackagePath, $DetectionScriptPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required file was not found: $path"
    }
}

$PackagePath = (Resolve-Path -LiteralPath $PackagePath).Path
$DetectionScriptPath = (Resolve-Path -LiteralPath $DetectionScriptPath).Path
if ($LogoPath) {
    if (-not (Test-Path -LiteralPath $LogoPath -PathType Leaf)) {
        throw "Company Portal icon was not found: $LogoPath"
    }
    $LogoPath = (Resolve-Path -LiteralPath $LogoPath).Path
}

if (-not $Developer) {
    $Developer = $Publisher
}
if (-not $PSBoundParameters.ContainsKey('Notes')) {
    $Notes = 'Created by Publish-IntuneWin32App.ps1. No assignments were created.'
}
if (-not $SummaryPath) {
    $safeName = ($DisplayName -replace '[^A-Za-z0-9._-]+', '-')
    $SummaryPath = Join-Path (Split-Path -Parent $PackagePath) "IntuneUpload-$safeName.json"
}
$SummaryPath = [IO.Path]::GetFullPath($SummaryPath)
if ($DeploymentIntent -eq 'UpdateExisting' -and -not $ExistingAppId) {
    throw 'UpdateExisting requires the exact ExistingAppId of the intended app.'
}
if ($NewDisplayName -and $DeploymentIntent -ne 'UpdateExisting') {
    throw 'NewDisplayName can only be used with -DeploymentIntent UpdateExisting.'
}
if ($DeploymentIntent -eq 'CreateSeparateTest' -and $ExistingAppId) {
    throw 'CreateSeparateTest cannot be combined with ExistingAppId. Create a separately named, unassigned app instead.'
}
if ($ExistingAppId -and $ReuseUnpublishedDraft) {
    throw 'ReuseUnpublishedDraft cannot be combined with ExistingAppId.'
}
if ($ActivateContentVersionId -and -not $ExistingAppId) {
    throw 'ActivateContentVersionId requires ExistingAppId.'
}
if ($DeploymentIntent -eq 'UpdateExisting' -and $PSBoundParameters.ContainsKey('InstallRunAsAccount')) {
    throw 'InstallRunAsAccount is create-time-only and cannot be supplied for UpdateExisting.'
}
if ([string]::IsNullOrWhiteSpace($Justification) -or $Justification.Length -gt 1024) {
    throw 'Justification must contain 1-1024 decoded characters.'
}
if ($Version -and $GraphApiVersion -ne 'beta') {
    throw 'Win32 displayVersion metadata requires GraphApiVersion beta. Pass -GraphApiVersion beta or omit -Version.'
}
$script:GraphBase = "https://graph.microsoft.com/$GraphApiVersion"
$script:MaaApproval = $null
$script:MaaTargetResourceId = $null

$packageInfo = $null
$app = $null
$contentVersion = $null
$script:LastContentFile = $null

try {
    $packageInfo = Get-IntuneWinPackageInfo -Path $PackagePath
    if ($packageInfo.SetupFile -ne $SetupFilePath) {
        throw "The .intunewin setup file is '$($packageInfo.SetupFile)', not '$SetupFilePath'."
    }

    $iconPayload = if ($LogoPath) { Get-PngIconPayload -Path $LogoPath } else { $null }
    $detectionContent = Get-Content -LiteralPath $DetectionScriptPath -Raw
    if ([string]::IsNullOrWhiteSpace($detectionContent)) {
        throw "Detection script is empty: $DetectionScriptPath"
    }

    $returnCodes = @(
        [ordered]@{ '@odata.type' = '#microsoft.graph.win32LobAppReturnCode'; returnCode = 0; type = 'success' },
        [ordered]@{ '@odata.type' = '#microsoft.graph.win32LobAppReturnCode'; returnCode = 3010; type = 'softReboot' },
        [ordered]@{ '@odata.type' = '#microsoft.graph.win32LobAppReturnCode'; returnCode = 1641; type = 'hardReboot' },
        [ordered]@{ '@odata.type' = '#microsoft.graph.win32LobAppReturnCode'; returnCode = 1618; type = 'retry' }
    )
    if ($ReturnCodeProfile -eq 'Default') {
        $returnCodes = @(
            $returnCodes[0],
            [ordered]@{ '@odata.type' = '#microsoft.graph.win32LobAppReturnCode'; returnCode = 1707; type = 'success' },
            $returnCodes[1],
            $returnCodes[2],
            $returnCodes[3]
        )
    }

    $appMetadataPayload = [ordered]@{
        '@odata.type' = '#microsoft.graph.win32LobApp'
        displayName = if ($NewDisplayName) { $NewDisplayName } else { $DisplayName }
        description = $Description
        publisher = $Publisher
        isFeatured = $false
        owner = $Owner
        developer = $Developer
        notes = $Notes
        installCommandLine = $InstallCommandLine
        uninstallCommandLine = $UninstallCommandLine
        allowedArchitectures = $Architecture
        rules = @(
            [ordered]@{
                '@odata.type' = '#microsoft.graph.win32LobAppPowerShellScriptRule'
                ruleType = 'detection'
                enforceSignatureCheck = $false
                runAs32Bit = $false
                scriptContent = ConvertTo-Base64Utf8 -Value $detectionContent
                operationType = 'notConfigured'
                operator = 'notConfigured'
            }
        )
        returnCodes = $returnCodes
        setupFilePath = $SetupFilePath
    }
    if ($DeploymentIntent -eq 'CreateSeparateTest') {
        $appMetadataPayload.installExperience = [ordered]@{
            '@odata.type' = '#microsoft.graph.win32LobAppInstallExperience'
            runAsAccount = $InstallRunAsAccount
            deviceRestartBehavior = 'basedOnReturnCode'
        }
    }
    if ($AvailableUninstallPolicy -ne 'Preserve') {
        $appMetadataPayload.allowAvailableUninstall = ($AvailableUninstallPolicy -eq 'Enable')
    }
    if ($iconPayload) {
        $appMetadataPayload.largeIcon = $iconPayload
    }
    if ($Version) {
        $appMetadataPayload.displayVersion = $Version
    }
    if ($InformationUrl) {
        $appMetadataPayload.informationUrl = $InformationUrl
    }
    if ($PrivacyInformationUrl) {
        $appMetadataPayload.privacyInformationUrl = $PrivacyInformationUrl
    }

    $appCreatePayload = [ordered]@{}
    foreach ($entry in $appMetadataPayload.GetEnumerator()) {
        $appCreatePayload[$entry.Key] = $entry.Value
    }
    $appCreatePayload.fileName = Split-Path -Leaf $PackagePath

    if ($planningOnly) {
        Write-Summary -Status 'whatIf'
        Write-Host "Validated package metadata and wrote WhatIf summary to $SummaryPath."
        return
    }

    if ($DeploymentIntent -eq 'UpdateExisting') {
        Write-Host 'Proceeding with an existing-app update. Assignments will not be changed.'
    }
    else {
        Write-Host 'Proceeding with a separate test app publication. No assignments will be created.'
    }

    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $requiredPermissions = @('DeviceManagementApps.ReadWrite.All', 'DeviceManagementRBAC.Read.All')

    # App-only (App B, "Contoso EUC Automation - Intune Write") is the default: it
    # survives the nightly z-account password rotation. -DelegatedGraph forces the old
    # z_admin path for the cases where a request has to be filed as a human.
    $graphAuthDir = 'C:\automox-mcp-main\scripts\graph-auth'
    . (Join-Path $graphAuthDir 'Assert-GraphToken.ps1')
    # App B is a DIFFERENT client id from the one GRAPH_APP_CLIENT_ID names, and
    # Assert-GraphToken invokes its helper with no arguments, so the App path has to be
    # pointed at the write wrapper explicitly - otherwise it mints the read identity and
    # then fails the DeviceManagementApps.ReadWrite.All check.
    $graphHelper = if ($DelegatedGraph) { Join-Path $graphAuthDir 'graph-token.cmd' }
                   else                 { Join-Path $graphAuthDir 'graph-app-token-write.cmd' }
    $graph = Assert-GraphToken `
        -Identity $(if ($DelegatedGraph) { 'Delegated' } else { 'App' }) `
        -Helper $graphHelper `
        -RequiredPermissions $requiredPermissions `
        -MinMinutesRemaining 30

    # ALWAYS install the token the preflight just validated. Do not try to reuse an
    # existing Get-MgContext: a stale MSAL session from an earlier run leaves Account
    # populated, which would skip the connect entirely and leave the script running on
    # a credential the preflight never checked. Connect-MgGraph is cheap; the guard was
    # not worth the ambiguity.
    Connect-MgGraph -AccessToken (ConvertTo-SecureString $graph.AccessToken -AsPlainText -Force) -NoWelcome | Out-Null
    $context = Get-MgContext
    if (-not $context) {
        throw 'Microsoft Graph context was not available after Connect-MgGraph.'
    }
    # Do NOT gate on $context.Account: it is empty for an app-only token, so the old
    # check here threw on every successful app-only connection.
    # Do NOT gate on $context.AuthType -eq 'AppOnly' either. On the -AccessToken path
    # AuthType is 'UserProvidedAccessToken' regardless of what is inside the token -
    # VERIFIED live, Microsoft.Graph.Authentication 2.38.0. 'AppOnly' only appears on the
    # -ClientId/-TenantId/-Certificate path. The authority on what kind of token this is
    # is $graph.AuthKind, which comes from the decoded claims.
    if ($context.TokenCredentialType -ne 'UserProvidedAccessToken') {
        throw "Expected a user-provided access token context, got TokenCredentialType=$($context.TokenCredentialType)."
    }
    $principal = if ($graph.AuthKind -eq 'app') { "app $($graph.AppId)" } else { $graph.Upn }
    Write-Host "Connected to Graph as $principal ($($graph.AuthKind)) in tenant $($context.TenantId)."

    if ($ExistingAppId) {
        $app = Invoke-GraphJson -Method GET -Uri "$script:GraphBase/deviceAppManagement/mobileApps/$ExistingAppId"
        if ($app.'@odata.type' -ne '#microsoft.graph.win32LobApp') {
            throw "Existing app '$ExistingAppId' is not a Win32 app."
        }
        if ($app.displayName -ne $DisplayName) {
            throw "Existing app '$ExistingAppId' is named '$($app.displayName)', not '$DisplayName'."
        }
        if ($app.installExperience.runAsAccount -ne 'system') {
            throw "Existing app '$ExistingAppId' does not run as SYSTEM. Refusing this SYSTEM package update."
        }
        # Accept both non-forcing behaviors: this script's own create path sets
        # 'basedOnReturnCode' (see the CreateSeparateTest installExperience above), so the
        # update guard must not demand 'suppress' — that made every self-created app
        # un-updatable (hit 2026-08-18 on app d8d5a2c6). Still refuse 'allow'/'force',
        # which could restart users mid-session on a silent update.
        if ($app.installExperience.deviceRestartBehavior -notin @('suppress', 'basedOnReturnCode')) {
            throw "Existing app '$ExistingAppId' restart behavior is '$($app.installExperience.deviceRestartBehavior)' (expected 'suppress' or 'basedOnReturnCode')."
        }
        if ([int] $app.installExperience.maxRunTimeInMinutes -ne 60) {
            throw "Existing app '$ExistingAppId' maximum run time is '$($app.installExperience.maxRunTimeInMinutes)', not 60 minutes."
        }
        Write-Host "Updating existing Intune app ID $($app.id). Assignments will be preserved."
        if ($NewDisplayName -and $NewDisplayName -ne $app.displayName) {
            $escapedNewName = $NewDisplayName.Replace("'", "''")
            $newNameFilter = [uri]::EscapeDataString("displayName eq '$escapedNewName'")
            $sameNameApps = @(Get-AllGraphPages -Uri "$script:GraphBase/deviceAppManagement/mobileApps?`$filter=$newNameFilter" |
                Where-Object { $_.id -ne $app.id })
            if ($sameNameApps.Count -gt 0) {
                $ids = ($sameNameApps | ForEach-Object { $_.id }) -join ', '
                throw "An Intune app named '$NewDisplayName' already exists (ID: $ids). Refusing to rename onto a duplicate."
            }
            Write-Host "App will be renamed to '$NewDisplayName' in the activation PATCH."
        }
    }
    else {
        $escapedDisplayName = $DisplayName.Replace("'", "''")
        $filter = [uri]::EscapeDataString("displayName eq '$escapedDisplayName'")
        $existingApps = @(Get-AllGraphPages -Uri "$script:GraphBase/deviceAppManagement/mobileApps?`$filter=$filter")

        if ($existingApps.Count -gt 0) {
            if (-not $ReuseUnpublishedDraft -or $existingApps.Count -ne 1) {
                $ids = ($existingApps | ForEach-Object { $_.id }) -join ', '
                throw "An Intune app named '$DisplayName' already exists (ID: $ids). Refusing to create a duplicate."
            }

            $candidate = Invoke-GraphJson -Method GET -Uri "$script:GraphBase/deviceAppManagement/mobileApps/$($existingApps[0].id)"
            if (
                $candidate.'@odata.type' -eq '#microsoft.graph.win32LobApp' -and
                [string]::IsNullOrWhiteSpace($candidate.committedContentVersion) -and
                $candidate.publishingState -eq 'notPublished' -and
                $candidate.notes -like 'Created by Publish-IntuneWin32App.ps1*'
            ) {
                $app = $candidate
                Write-Host "Reusing unpublished app ID $($app.id)."
            }
            else {
                throw "The same-name app cannot be safely reused (ID: $($candidate.id))."
            }
        }
        else {
            Write-Host 'Creating Intune Win32 app metadata.'
            $app = Invoke-GraphJson -Method POST -Uri "$script:GraphBase/deviceAppManagement/mobileApps" -Body $appCreatePayload -UseMaaJustification
            Write-Host "Created app ID $($app.id)."
        }
    }

    $script:MaaTargetResourceId = $app.id

    if ($ActivateContentVersionId) {
        $resumeResponse = Invoke-GraphJson -Method GET -Uri "$script:GraphBase/deviceAppManagement/mobileApps/$($app.id)/microsoft.graph.win32LobApp/contentVersions/$ActivateContentVersionId/files"
        $resumeFiles = @($resumeResponse.value)
        if ($resumeFiles.Count -ne 1) {
            throw "Content version '$ActivateContentVersionId' does not contain exactly one content file."
        }
        $script:LastContentFile = $resumeFiles[0]
        if (-not $script:LastContentFile.isCommitted -or $script:LastContentFile.uploadState -ne 'commitFileSuccess') {
            throw "Content version '$ActivateContentVersionId' is not ready to activate (state: $($script:LastContentFile.uploadState))."
        }
        $contentVersion = [pscustomobject]@{ id = $ActivateContentVersionId }
        Write-Host "Resuming activation of committed content version $ActivateContentVersionId."
    }
    else {
        Write-Host 'Creating content version.'
        $contentVersion = Invoke-GraphJson -Method POST -Uri "$script:GraphBase/deviceAppManagement/mobileApps/$($app.id)/microsoft.graph.win32LobApp/contentVersions" -Body @{} -UseMaaJustification

        $filePayload = [ordered]@{
            '@odata.type' = '#microsoft.graph.mobileAppContentFile'
            name = $packageInfo.FileName
            size = $packageInfo.UnencryptedSize
            sizeEncrypted = $packageInfo.EncryptedSize
            manifest = $null
            isDependency = $false
        }

        Write-Host 'Creating content file placeholder.'
        $contentFile = Invoke-GraphJson -Method POST -Uri "$script:GraphBase/deviceAppManagement/mobileApps/$($app.id)/microsoft.graph.win32LobApp/contentVersions/$($contentVersion.id)/files" -Body $filePayload -UseMaaJustification
        $contentFile = Wait-MobileAppContentFile -AppId $app.id -ContentVersionId $contentVersion.id -FileId $contentFile.id -SuccessStates @('azureStorageUriRequestSuccess') -FailureStates @('azureStorageUriRequestFailed', 'azureStorageUriRequestTimedOut', 'error')
        if ([string]::IsNullOrWhiteSpace($contentFile.azureStorageUri)) {
            throw 'Content file reached azureStorageUriRequestSuccess but did not include an Azure Storage URI.'
        }

        Write-Host 'Uploading encrypted payload to Intune storage.'
        Invoke-AzureStorageBlobUpload -StorageUri $contentFile.azureStorageUri -FilePath $packageInfo.EncryptedPayloadPath

        $commitPayload = [ordered]@{
            fileEncryptionInfo = $packageInfo.EncryptionInfo
        }
        Write-Host 'Committing uploaded file.'
        Invoke-GraphJson -Method POST -Uri "$script:GraphBase/deviceAppManagement/mobileApps/$($app.id)/microsoft.graph.win32LobApp/contentVersions/$($contentVersion.id)/files/$($contentFile.id)/commit" -Body $commitPayload -UseMaaJustification | Out-Null
        Wait-MobileAppContentFile -AppId $app.id -ContentVersionId $contentVersion.id -FileId $contentFile.id -SuccessStates @('commitFileSuccess') -FailureStates @('commitFileFailed', 'commitFileTimedOut', 'error') | Out-Null
    }

    $activationPayload = [ordered]@{}
    foreach ($entry in $appMetadataPayload.GetEnumerator()) {
        $activationPayload[$entry.Key] = $entry.Value
    }
    $activationPayload.committedContentVersion = $contentVersion.id

    Write-Host 'Activating the content version and metadata together.'
    Invoke-GraphJson -Method PATCH -Uri "$script:GraphBase/deviceAppManagement/mobileApps/$($app.id)" -Body $activationPayload -UseMaaJustification | Out-Null

    $publishedApp = Wait-MobileAppPublished -AppId $app.id
    Write-Summary -Status 'uploaded' -App $publishedApp
    Write-Host "Upload complete. Summary written to $SummaryPath. No assignments were created."
}
catch {
    if ($script:MaaApproval) {
        $request = $null
        if ($script:MaaApproval.requestId) {
            $request = Get-MaaRequestStatus -RequestId $script:MaaApproval.requestId
        }
        if (-not $request -and $script:MaaTargetResourceId) {
            $request = Get-ActiveMaaRequestForResource -TargetResourceId $script:MaaTargetResourceId
        }
        if ($request) {
            $script:MaaApproval.requestId = $request.id
            $script:MaaApproval.status = $request.status
            $script:MaaApproval | Add-Member -NotePropertyName displayName -NotePropertyValue $request.payloadName -Force
            $script:MaaApproval | Add-Member -NotePropertyName requestor -NotePropertyValue $request.requestor -Force
            $script:MaaApproval | Add-Member -NotePropertyName expirationDateTime -NotePropertyValue $request.expirationDateTime -Force
        }

        Write-Summary -Status 'approvalRequired' -App $app -Approval $script:MaaApproval -ErrorMessage $_.Exception.Message
        Write-Host "MAA approval required. Request ID: $($script:MaaApproval.requestId). Summary written to $SummaryPath."
        exit 0
    }

    Write-Summary -Status 'failed' -App $app -ErrorMessage $_.Exception.Message
    throw
}
finally {
    if ($packageInfo -and $packageInfo.TempDir -and (Test-Path -LiteralPath $packageInfo.TempDir)) {
        Remove-Item -LiteralPath $packageInfo.TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
