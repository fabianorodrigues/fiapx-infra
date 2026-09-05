param(
    [string]$InfraPath = $env:DEPLOY_INFRA_PATH,
    [string]$DeploySha = $env:DEPLOY_SHA,
    [string]$Repository = $env:GITHUB_REPOSITORY,
    [string]$GitHubServerUrl = $env:GITHUB_SERVER_URL,
    [string]$GitHubToken = $env:GITHUB_TOKEN,
    [string]$BootstrapVideoManagementImage = $env:BOOTSTRAP_VIDEO_MANAGEMENT_IMAGE,
    [string]$BootstrapVideoProcessingImage = $env:BOOTSTRAP_VIDEO_PROCESSING_IMAGE
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LockName = 'Global\FiapXDeployLock'
$LockTimeout = [TimeSpan]::FromMinutes(15)
$ProjectName = 'fiap-fase5'
$ProcessorServiceName = 'video-processing-service'
$ManagementServiceName = 'video-management-service'
$MigrationServiceName = 'video-management-migrations'
$ProcessingQueueName = 'video.processing'

$script:ComposeFile = $null
$script:EnvFile = $null
$script:ProcessorScaleDetected = 0
$script:ProcessorScaleTarget = 1
$script:ManagementImage = $null
$script:ProcessingImage = $null
$script:GitServerUrl = $null
$script:ExpectedRemote = $null
$script:OperationalHead = $null
$script:EnvCreated = $false
$script:RabbitConsumers = $null

function Assert-NotBlank {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name must not be empty."
    }
}

function Assert-CommitSha {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][string]$Value
    )

    Assert-NotBlank -Name $Name -Value $Value
    if ($Value -notmatch '^[a-fA-F0-9]{40}$') {
        throw "$Name must be a full 40-character commit SHA."
    }
}

function Invoke-NativeOutput {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )

    $output = & $FilePath @Arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$FilePath $($Arguments -join ' ') failed with exit code $exitCode."
    }

    return @($output)
}

function Invoke-DockerOutput {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    return Invoke-NativeOutput docker @Arguments
}

function Invoke-ComposeOutput {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

    $composeArguments = @('compose', '--env-file', $script:EnvFile, '-f', $script:ComposeFile) + $Arguments
    return Invoke-NativeOutput docker @composeArguments
}

function Invoke-GitOutput {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    return Invoke-NativeOutput git @Arguments
}

function Invoke-GitWithToken {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

    Assert-NotBlank -Name 'GITHUB_TOKEN' -Value $GitHubToken

    $previousCount = [Environment]::GetEnvironmentVariable('GIT_CONFIG_COUNT', 'Process')
    $previousKey = [Environment]::GetEnvironmentVariable('GIT_CONFIG_KEY_0', 'Process')
    $previousValue = [Environment]::GetEnvironmentVariable('GIT_CONFIG_VALUE_0', 'Process')
    $tokenBytes = [Text.Encoding]::ASCII.GetBytes("x-access-token:$GitHubToken")
    $tokenHeader = 'AUTHORIZATION: basic ' + [Convert]::ToBase64String($tokenBytes)

    try {
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT', '1', 'Process')
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_KEY_0', "http.$script:GitServerUrl/.extraheader", 'Process')
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_VALUE_0', $tokenHeader, 'Process')
        return Invoke-GitOutput @Arguments
    }
    finally {
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT', $previousCount, 'Process')
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_KEY_0', $previousKey, 'Process')
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_VALUE_0', $previousValue, 'Process')
    }
}

function Assert-PathExists {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description,
        [ValidateSet('Container', 'Leaf')][string]$PathType
    )

    if (-not (Test-Path -LiteralPath $Path -PathType $PathType)) {
        throw "$Description not found: $Path"
    }
}

function Read-DotEnv {
    param([Parameter(Mandatory = $true)][string]$Path)

    $values = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
            continue
        }

        $separator = $line.IndexOf('=')
        if ($separator -le 0) {
            continue
        }

        $name = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        $values[$name] = $value
    }

    return $values
}

function Get-EnvValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $values = Read-DotEnv -Path $Path
    if (-not $values.Contains($Name)) {
        throw "$Name was not found in $Path."
    }

    return [string]$values[$Name]
}

function Get-TextEncoding {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return New-Object Text.UTF8Encoding($true)
    }

    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [Text.Encoding]::Unicode
    }

    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return [Text.Encoding]::BigEndianUnicode
    }

    return New-Object Text.UTF8Encoding($false)
}

function Set-EnvValueAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $encoding = Get-TextEncoding -Path $Path
    $content = [IO.File]::ReadAllText($Path, $encoding)
    $pattern = "(?m)^(?!\s*#)(\s*$([regex]::Escape($Name))\s*=\s*).*$"
    $regex = New-Object regex($pattern)
    if (-not $regex.IsMatch($content)) {
        throw "$Name was not found in $Path."
    }

    $newContent = $regex.Replace($content, { param($match) $match.Groups[1].Value + $Value }, 1)
    $directory = Split-Path -Parent $Path
    $tempPath = Join-Path $directory ('.env.tmp.' + [Guid]::NewGuid().ToString('N'))
    $backupPath = Join-Path $directory ('.env.bak.' + [Guid]::NewGuid().ToString('N'))

    [IO.File]::WriteAllText($tempPath, $newContent, $encoding)
    try {
        [IO.File]::Replace($tempPath, $Path, $backupPath, $true)
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
            Remove-Item -LiteralPath $backupPath -Force
        }
    }
    catch {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force
        }
        throw
    }
}

function Assert-MicroserviceImage {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][string]$Image
    )

    Assert-NotBlank -Name $Name -Value $Image

    if ($Image -match '(^|:)latest$') {
        throw "$Name must never use latest."
    }

    $shaTag = $Image -match '^ghcr\.io/[^/]+/[^:@]+:[a-f0-9]{40}$'
    $shaDigest = $Image -match '^ghcr\.io/[^/]+/[^:@]+@sha256:[a-f0-9]{64}$'
    if (-not ($shaTag -or $shaDigest)) {
        throw "$Name must be a GHCR image pinned by commit SHA tag or sha256 digest. Value=$Image"
    }
}

function Assert-ComposeImage {
    param(
        [Parameter(Mandatory = $true)][string]$Service,
        [Parameter(Mandatory = $true)][string]$ExpectedImage
    )

    $json = (Invoke-ComposeOutput 'config' '--format' 'json') -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($json)) {
        throw 'docker compose config returned empty JSON.'
    }

    $config = $json | ConvertFrom-Json
    $serviceConfig = $config.services.PSObject.Properties[$Service]
    if ($null -eq $serviceConfig) {
        throw "Service $Service was not found in compose config."
    }

    $actual = $serviceConfig.Value.image
    if ($actual -ne $ExpectedImage) {
        throw "Service $Service resolved image [$actual], expected [$ExpectedImage]."
    }
}

function Get-ProcessorRuntimeContainerIds {
    $ids = Invoke-DockerOutput `
        'ps' '-a' '-q' `
        '--filter' "label=com.docker.compose.project=$ProjectName" `
        '--filter' "label=com.docker.compose.service=$ProcessorServiceName" `
        '--filter' 'label=com.docker.compose.oneoff=False'

    return @($ids | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object)
}

function Capture-ProcessorScale {
    $ids = @(Get-ProcessorRuntimeContainerIds)
    $script:ProcessorScaleDetected = $ids.Count
    if ($script:ProcessorScaleDetected -ge 1) {
        $script:ProcessorScaleTarget = $script:ProcessorScaleDetected
    }
    else {
        $script:ProcessorScaleTarget = 1
    }

    Write-Host "Processor runtime scale detected: $script:ProcessorScaleDetected. Target scale: $script:ProcessorScaleTarget."
}

function Normalize-RepoUrl {
    param([Parameter(Mandatory = $true)][string]$Url)

    $normalized = $Url.Trim().TrimEnd('/')
    if ($normalized.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(0, $normalized.Length - 4)
    }

    return $normalized.ToLowerInvariant()
}

function Assert-GitClean {
    param([Parameter(Mandatory = $true)][string]$Path)

    $trackedChanges = @(Invoke-GitOutput '-C' $Path 'status' '--porcelain' '--untracked-files=no')
    if ($trackedChanges.Count -gt 0) {
        throw "Operational working tree has versioned changes. Clean it before deploy: $Path"
    }

    $untracked = @(Invoke-GitOutput '-C' $Path 'ls-files' '--others' '--exclude-standard')
    if ($untracked.Count -gt 0) {
        throw "Operational working tree has untracked non-ignored files: $($untracked -join ', ')"
    }
}

function Ensure-OperationalCopy {
    Assert-NotBlank -Name 'DEPLOY_INFRA_PATH' -Value $InfraPath
    Assert-CommitSha -Name 'DEPLOY_SHA/DeploySha' -Value $DeploySha
    Assert-NotBlank -Name 'GITHUB_REPOSITORY' -Value $Repository

    if ([string]::IsNullOrWhiteSpace($GitHubServerUrl)) {
        $GitHubServerUrl = 'https://github.com'
    }

    $script:GitServerUrl = $GitHubServerUrl.TrimEnd('/')
    $script:ExpectedRemote = "$script:GitServerUrl/$Repository.git"

    if (-not (Test-Path -LiteralPath $InfraPath -PathType Container)) {
        New-Item -ItemType Directory -Path $InfraPath -Force | Out-Null
    }

    $children = @(Get-ChildItem -LiteralPath $InfraPath -Force)
    $gitDir = Join-Path $InfraPath '.git'
    if (-not (Test-Path -LiteralPath $gitDir -PathType Container)) {
        if ($children.Count -gt 0) {
            throw "DEPLOY_INFRA_PATH exists but is not an empty Git working tree: $InfraPath"
        }

        [void](Invoke-GitOutput '-C' $InfraPath 'init')
        [void](Invoke-GitOutput '-C' $InfraPath 'remote' 'add' 'origin' $script:ExpectedRemote)
    }
    else {
        Assert-GitClean -Path $InfraPath
        $origin = ((Invoke-GitOutput '-C' $InfraPath 'remote' 'get-url' 'origin') | Select-Object -First 1).Trim()
        if ((Normalize-RepoUrl $origin) -ne (Normalize-RepoUrl $script:ExpectedRemote)) {
            throw "Operational origin mismatch. Expected=$script:ExpectedRemote Actual=$origin"
        }
    }

    [void](Invoke-GitWithToken '-C' $InfraPath 'fetch' '--no-tags' '--depth' '1' 'origin' $DeploySha)
    [void](Invoke-GitOutput '-C' $InfraPath 'checkout' '--detach' $DeploySha)

    $head = ((Invoke-GitOutput '-C' $InfraPath 'rev-parse' 'HEAD') | Select-Object -First 1).Trim()
    if (-not $head.Equals($DeploySha, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Operational checkout did not reach deploy SHA. Expected=$DeploySha Actual=$head"
    }

    $script:OperationalHead = $head
    Write-Host "Operational copy ready at $InfraPath HEAD=$head."
}

function Ensure-EnvFile {
    $script:ComposeFile = Join-Path $InfraPath 'docker-compose.yml'
    $script:EnvFile = Join-Path $InfraPath '.env'
    $envExamplePath = Join-Path $InfraPath '.env.example'

    Assert-PathExists -Path $script:ComposeFile -Description 'Compose file' -PathType Leaf
    Assert-PathExists -Path $envExamplePath -Description '.env.example' -PathType Leaf

    if (Test-Path -LiteralPath $script:EnvFile -PathType Leaf) {
        return
    }

    Assert-MicroserviceImage -Name 'BOOTSTRAP_VIDEO_MANAGEMENT_IMAGE' -Image $BootstrapVideoManagementImage
    Assert-MicroserviceImage -Name 'BOOTSTRAP_VIDEO_PROCESSING_IMAGE' -Image $BootstrapVideoProcessingImage

    Copy-Item -LiteralPath $envExamplePath -Destination $script:EnvFile
    Set-EnvValueAtomic -Path $script:EnvFile -Name 'VIDEO_MANAGEMENT_IMAGE' -Value $BootstrapVideoManagementImage
    Set-EnvValueAtomic -Path $script:EnvFile -Name 'VIDEO_PROCESSING_IMAGE' -Value $BootstrapVideoProcessingImage
    $script:EnvCreated = $true
    Write-Host '.env created from .env.example with bootstrap microservice images.'
}

function Validate-EnvAndCompose {
    $values = Read-DotEnv -Path $script:EnvFile
    $requiredRuntimeKeys = @(
        'POSTGRES_DB',
        'POSTGRES_USER',
        'POSTGRES_PASSWORD',
        'REDIS_PORT',
        'KEYCLOAK_PORT',
        'KEYCLOAK_HOSTNAME',
        'KEYCLOAK_ADMIN_USERNAME',
        'KEYCLOAK_ADMIN_PASSWORD',
        'JWT_METADATA_ADDRESS',
        'JWT_ISSUER',
        'JWT_AUDIENCE',
        'MINIO_ROOT_USER',
        'MINIO_ROOT_PASSWORD',
        'MINIO_BUCKET',
        'MINIO_API_PORT',
        'MINIO_CONSOLE_PORT',
        'MINIO_PUBLIC_ENDPOINT',
        'MINIO_REGION',
        'VIDEO_MANAGEMENT_IMAGE',
        'VIDEO_PROCESSING_IMAGE',
        'VIDEO_MANAGEMENT_PORT',
        'MAILPIT_WEB_PORT',
        'RABBITMQ_DEFAULT_USER',
        'RABBITMQ_DEFAULT_PASS',
        'RABBITMQ_MANAGEMENT_PORT'
    )

    foreach ($key in $requiredRuntimeKeys) {
        if (-not $values.Contains($key) -or [string]::IsNullOrWhiteSpace([string]$values[$key])) {
            throw ".env missing required runtime key: $key"
        }
    }

    $script:ManagementImage = [string]$values['VIDEO_MANAGEMENT_IMAGE']
    $script:ProcessingImage = [string]$values['VIDEO_PROCESSING_IMAGE']
    Assert-MicroserviceImage -Name 'VIDEO_MANAGEMENT_IMAGE' -Image $script:ManagementImage
    Assert-MicroserviceImage -Name 'VIDEO_PROCESSING_IMAGE' -Image $script:ProcessingImage

    [void](Invoke-ComposeOutput 'config' '--quiet')
    Assert-ComposeImage -Service $ManagementServiceName -ExpectedImage $script:ManagementImage
    Assert-ComposeImage -Service $MigrationServiceName -ExpectedImage $script:ManagementImage
    Assert-ComposeImage -Service $ProcessorServiceName -ExpectedImage $script:ProcessingImage
}

function Get-ContainerScalar {
    param(
        [Parameter(Mandatory = $true)][string]$ContainerId,
        [Parameter(Mandatory = $true)][string]$Format
    )

    return ((Invoke-DockerOutput 'inspect' '--format' $Format $ContainerId) | Select-Object -First 1).Trim()
}

function Get-ServiceContainerIds {
    param([Parameter(Mandatory = $true)][string]$Service)

    $ids = Invoke-ComposeOutput 'ps' '-a' '-q' $Service
    return @($ids | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object)
}

function Wait-Until {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Condition,
        [int]$TimeoutSeconds = 180,
        [int]$IntervalSeconds = 3
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastError = $null
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        try {
            $result = & $Condition
            if ($result) {
                return $result
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }

        Start-Sleep -Seconds $IntervalSeconds
    }

    if ($lastError) {
        throw "Timed out waiting for $Name. Last error: $lastError"
    }

    throw "Timed out waiting for $Name."
}

function Wait-ServiceRunning {
    param(
        [Parameter(Mandatory = $true)][string]$Service,
        [int]$ExpectedCount = 1,
        [int]$TimeoutSeconds = 180
    )

    Wait-Until -Name "$Service running" -TimeoutSeconds $TimeoutSeconds -Condition {
        $ids = @(Get-ServiceContainerIds -Service $Service)
        if ($ids.Count -ne $ExpectedCount) {
            return $false
        }

        foreach ($id in $ids) {
            $running = Get-ContainerScalar -ContainerId $id -Format '{{.State.Running}}'
            if ($running -ne 'true') {
                return $false
            }
        }

        return $ids
    } | Out-Null
}

function Wait-ServiceHealthy {
    param(
        [Parameter(Mandatory = $true)][string]$Service,
        [int]$TimeoutSeconds = 180
    )

    Wait-ServiceRunning -Service $Service -TimeoutSeconds $TimeoutSeconds
    Wait-Until -Name "$Service healthy" -TimeoutSeconds $TimeoutSeconds -Condition {
        $ids = @(Get-ServiceContainerIds -Service $Service)
        if ($ids.Count -ne 1) {
            return $false
        }

        $health = Get-ContainerScalar -ContainerId $ids[0] -Format '{{if .State.Health}}{{.State.Health.Status}}{{else}}not-configured{{end}}'
        if ($health -eq 'healthy') {
            return $true
        }

        return $false
    } | Out-Null
}

function Wait-HttpOk {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Uri,
        [int]$TimeoutSeconds = 180
    )

    Wait-Until -Name $Name -TimeoutSeconds $TimeoutSeconds -Condition {
        $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 5
        return ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 300)
    } | Out-Null
}

function Wait-BaseInfrastructure {
    $values = Read-DotEnv -Path $script:EnvFile
    Wait-ServiceHealthy -Service 'postgres'
    Wait-ServiceHealthy -Service 'redis'
    Wait-ServiceHealthy -Service 'rabbitmq'
    Wait-ServiceHealthy -Service 'minio'
    Wait-ServiceRunning -Service 'keycloak'
    Wait-ServiceRunning -Service 'mailpit'
    Wait-HttpOk -Name 'Keycloak realm' -Uri "http://localhost:$($values['KEYCLOAK_PORT'])/realms/fiapx"
    Wait-HttpOk -Name 'Mailpit web UI' -Uri "http://localhost:$($values['MAILPIT_WEB_PORT'])"
}

function Reconcile-RabbitMq {
    [void](Invoke-ComposeOutput 'exec' '-T' 'rabbitmq' 'rabbitmqctl' 'await_startup' '--timeout' '30')
    [void](Invoke-ComposeOutput 'exec' '-T' 'rabbitmq' 'rabbitmqctl' 'import_definitions' '/etc/rabbitmq/definitions.json')

    Wait-Until -Name 'RabbitMQ imported topology' -TimeoutSeconds 120 -Condition {
        $queues = Invoke-ComposeOutput 'exec' '-T' 'rabbitmq' 'rabbitmqctl' 'list_queues' 'name' '--formatter' 'json'
        $json = $queues -join [Environment]::NewLine
        if ([string]::IsNullOrWhiteSpace($json)) {
            return $false
        }

        $parsed = $json | ConvertFrom-Json
        $names = @($parsed | ForEach-Object { $_.name })
        return ($names -contains 'video.processing' -and $names -contains 'video.status-updates')
    } | Out-Null
}

function Wait-Management {
    $values = Read-DotEnv -Path $script:EnvFile
    Wait-ServiceHealthy -Service $ManagementServiceName
    Wait-HttpOk -Name 'Video Management /health' -Uri "http://localhost:$($values['VIDEO_MANAGEMENT_PORT'])/health"
}

function Wait-Processor {
    Wait-Until -Name "Processor scale $script:ProcessorScaleTarget" -TimeoutSeconds 180 -Condition {
        $ids = @(Get-ProcessorRuntimeContainerIds)
        if ($ids.Count -ne $script:ProcessorScaleTarget) {
            return $false
        }

        foreach ($id in $ids) {
            $running = Get-ContainerScalar -ContainerId $id -Format '{{.State.Running}}'
            if ($running -ne 'true') {
                return $false
            }
        }

        return $ids
    } | Out-Null

    Wait-Until -Name "RabbitMQ consumers for $ProcessingQueueName" -TimeoutSeconds 120 -Condition {
        $queues = Invoke-ComposeOutput 'exec' '-T' 'rabbitmq' 'rabbitmqctl' 'list_queues' 'name' 'consumers' '--formatter' 'json'
        $json = $queues -join [Environment]::NewLine
        if ([string]::IsNullOrWhiteSpace($json)) {
            return $false
        }

        $parsed = $json | ConvertFrom-Json
        foreach ($queue in @($parsed)) {
            if ($queue.name -eq $ProcessingQueueName) {
                $script:RabbitConsumers = [int]$queue.consumers
                return ([int]$queue.consumers -ge $script:ProcessorScaleTarget)
            }
        }

        return $false
    } | Out-Null
}

function Add-StepSummary {
    if ([string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        return
    }

    $lines = @(
        '### Deploy Infra',
        '',
        '| Item | Value |',
        '| --- | --- |',
        "| Operational path | $InfraPath |",
        "| Deploy SHA | $DeploySha |",
        "| Operational HEAD | $script:OperationalHead |",
        "| .env created | $script:EnvCreated |",
        "| Management image | $script:ManagementImage |",
        "| Processing image | $script:ProcessingImage |",
        "| Processor scale detected | $script:ProcessorScaleDetected |",
        "| Processor scale applied | $script:ProcessorScaleTarget |",
        "| RabbitMQ consumer_count | $script:RabbitConsumers |",
        '| Health | PASS |'
    )

    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $lines
}

function Invoke-Deploy {
    Assert-CommitSha -Name 'DEPLOY_SHA/DeploySha' -Value $DeploySha

    [void](Invoke-DockerOutput 'version')
    [void](Invoke-DockerOutput 'compose' 'version')

    Capture-ProcessorScale
    Ensure-OperationalCopy
    Ensure-EnvFile
    Validate-EnvAndCompose

    Push-Location $InfraPath
    try {
        $pullServices = @(
            'postgres',
            'redis',
            'rabbitmq',
            'minio',
            'minio-init',
            'keycloak',
            'mailpit',
            $MigrationServiceName,
            $ManagementServiceName,
            $ProcessorServiceName
        )
        [void](Invoke-ComposeOutput 'pull' @pullServices)

        [void](Invoke-ComposeOutput 'up' '-d' 'postgres' 'redis' 'rabbitmq' 'minio' 'keycloak' 'mailpit')
        Wait-BaseInfrastructure

        Reconcile-RabbitMq

        [void](Invoke-ComposeOutput 'run' '--rm' '--no-deps' 'minio-init')
        [void](Invoke-ComposeOutput 'run' '--rm' '--no-deps' $MigrationServiceName)

        [void](Invoke-ComposeOutput 'up' '-d' '--no-deps' '--force-recreate' $ManagementServiceName)
        Wait-Management

        [void](Invoke-ComposeOutput 'up' '-d' '--no-deps' '--force-recreate' '--scale' "$ProcessorServiceName=$script:ProcessorScaleTarget" $ProcessorServiceName)
        Wait-Processor

        Add-StepSummary
        Write-Host "Deploy Infra PASS. Path=$InfraPath Head=$script:OperationalHead ProcessorScale=$script:ProcessorScaleTarget Consumers=$script:RabbitConsumers"
    }
    finally {
        Pop-Location
    }
}

$mutex = New-Object System.Threading.Mutex($false, $LockName)
$lockAcquired = $false
try {
    try {
        $lockAcquired = $mutex.WaitOne($LockTimeout)
    }
    catch [System.Threading.AbandonedMutexException] {
        $lockAcquired = $true
        Write-Warning 'Deploy mutex was abandoned by a previous process. Continuing with acquired lock.'
    }

    if (-not $lockAcquired) {
        throw "Could not acquire deploy lock $LockName within $($LockTimeout.TotalMinutes) minutes."
    }

    Invoke-Deploy
}
finally {
    if ($lockAcquired) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
