[CmdletBinding()]
param(
    [string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
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

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-PathExists {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description,
        [ValidateSet('Container', 'Leaf')][string]$PathType
    )

    Assert-True (Test-Path -LiteralPath $Path -PathType $PathType) "$Description not found: $Path"
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    }
    catch {
        throw "Invalid JSON file: $Path. $($_.Exception.Message)"
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

function Assert-SetEquals {
    param(
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string[]]$Actual,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $expectedSorted = @($Expected | Sort-Object)
    $actualSorted = @($Actual | Sort-Object)
    $missing = @($expectedSorted | Where-Object { $actualSorted -notcontains $_ })
    $extra = @($actualSorted | Where-Object { $expectedSorted -notcontains $_ })
    Assert-True ($missing.Count -eq 0 -and $extra.Count -eq 0) "$Name mismatch. Missing=[$($missing -join ', ')] Extra=[$($extra -join ', ')]"
}

function Assert-ImageReference {
    param(
        [Parameter(Mandatory = $true)][string]$Service,
        [AllowNull()][string]$Image
    )

    Assert-True (-not [string]::IsNullOrWhiteSpace($Image)) "Service $Service must define an image."
    Assert-True ($Image -notmatch '(^|:)latest$') "Service $Service must not use latest: $Image"

    $hasDigest = $Image -match '@sha256:[a-fA-F0-9]{64}$'
    $hasTag = $Image -match ':[^/:@]+$'
    Assert-True ($hasDigest -or $hasTag) "Service $Service image must use an explicit tag or digest: $Image"
}

function Assert-PowerShellParses {
    param([Parameter(Mandatory = $true)][string]$Path)

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    $errors = @($parseErrors)
    if ($errors.Count -gt 0) {
        $messages = @($errors | ForEach-Object { $_.Message })
        throw "PowerShell parse errors in $Path`: $($messages -join '; ')"
    }
}

function Invoke-ComposeJson {
    param([Parameter(Mandatory = $true)][string[]]$ComposeFiles)

    $arguments = @('compose', '--env-file', '.env.example')
    foreach ($composeFile in $ComposeFiles) {
        $arguments += @('-f', $composeFile)
    }

    $quietArguments = $arguments + @('config', '--quiet')
    [void](Invoke-NativeOutput docker @quietArguments)

    $jsonArguments = $arguments + @('config', '--format', 'json')
    $json = (Invoke-NativeOutput docker @jsonArguments) -join [Environment]::NewLine
    Assert-True (-not [string]::IsNullOrWhiteSpace($json)) 'docker compose config returned empty JSON.'
    return $json | ConvertFrom-Json
}

Push-Location $RepoRoot
try {
    $requiredFiles = @(
        'docker-compose.yml',
        'docker-compose.dev.yml',
        '.env.example',
        '.gitignore',
        'README.md',
        'rabbitmq/rabbitmq.conf',
        'rabbitmq/definitions.json',
        'keycloak/fiapx-realm.json',
        'scripts/e2e-rabbitmq.ps1',
        '.github/workflows/ci.yml',
        '.github/scripts/validate-infra.ps1',
        '.github/scripts/deploy-infra.ps1'
    )

    foreach ($file in $requiredFiles) {
        Assert-PathExists -Path (Join-Path $RepoRoot $file) -Description $file -PathType Leaf
    }

    $trackedEnvFiles = @(Invoke-NativeOutput git 'ls-files' '--' '.env' '.env.*' | Where-Object { $_ -ne '.env.example' })
    Assert-True ($trackedEnvFiles.Count -eq 0) "Private env files must not be tracked: $($trackedEnvFiles -join ', ')"

    foreach ($script in @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot '.github/scripts') -Filter '*.ps1') + @(Get-Item -LiteralPath (Join-Path $RepoRoot 'scripts/e2e-rabbitmq.ps1'))) {
        Assert-PowerShellParses -Path $script.FullName
    }

    $envExample = Read-DotEnv -Path (Join-Path $RepoRoot '.env.example')
    $requiredEnvKeys = @(
        'POSTGRES_DB',
        'POSTGRES_USER',
        'POSTGRES_PASSWORD',
        'POSTGRES_PORT',
        'REDIS_PORT',
        'CACHE_TTL_SECONDS',
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
        'MINIO_INTERNAL_ENDPOINT',
        'MINIO_PUBLIC_ENDPOINT',
        'MINIO_REGION',
        'MINIO_REQUEST_TIMEOUT_SECONDS',
        'MINIO_MAX_ERROR_RETRY',
        'PRESIGNED_URL_EXPIRES_SECONDS',
        'VIDEO_MANAGEMENT_IMAGE',
        'VIDEO_PROCESSING_IMAGE',
        'VIDEO_MANAGEMENT_PORT',
        'MAILPIT_SMTP_PORT',
        'MAILPIT_WEB_PORT',
        'SMTP_HOST',
        'SMTP_PORT',
        'SMTP_FROM',
        'RABBITMQ_DEFAULT_USER',
        'RABBITMQ_DEFAULT_PASS',
        'RABBITMQ_HOST',
        'RABBITMQ_PORT',
        'RABBITMQ_VHOST',
        'RABBITMQ_AMQP_PORT',
        'RABBITMQ_MANAGEMENT_PORT',
        'PROCESSING_MAX_ATTEMPTS',
        'PROCESSING_RETRY_DELAY_MS',
        'STATUS_MAX_ATTEMPTS',
        'STATUS_RETRY_DELAY_MS',
        'FIAPX_E2E_USERTEST1_USERNAME',
        'FIAPX_E2E_USERTEST1_PASSWORD',
        'FIAPX_E2E_USERTEST2_USERNAME',
        'FIAPX_E2E_USERTEST2_PASSWORD',
        'FIAPX_E2E_BOOTSTRAP_USERS'
    )

    foreach ($key in $requiredEnvKeys) {
        Assert-True ($envExample.Contains($key)) ".env.example missing key: $key"
    }

    Assert-True ($envExample['FIAPX_E2E_USERTEST1_USERNAME'] -eq 'usertest1') '.env.example must use usertest1 as the primary DEMO user.'
    Assert-True ($envExample['FIAPX_E2E_USERTEST2_USERNAME'] -eq 'usertest2') '.env.example must use usertest2 as the secondary DEMO user.'
    Assert-True (-not ($envExample.Keys | Where-Object { $_ -match 'ALICE' })) '.env.example must not define Alice-specific E2E keys.'

    $forbiddenSecretPatterns = @(
        'ghp_[A-Za-z0-9_]+',
        'github_pat_[A-Za-z0-9_]+',
        'AKIA[0-9A-Z]{16}',
        '-----BEGIN [A-Z ]*PRIVATE KEY-----',
        'xox[baprs]-[A-Za-z0-9-]+'
    )

    foreach ($entry in $envExample.GetEnumerator()) {
        foreach ($pattern in $forbiddenSecretPatterns) {
            Assert-True ([string]$entry.Value -notmatch $pattern) ".env.example contains a value that looks like a real secret in $($entry.Key)."
        }
    }

    $rabbit = Read-JsonFile -Path (Join-Path $RepoRoot 'rabbitmq/definitions.json')
    $expectedQueues = @(
        'video.processing',
        'video.processing.retry',
        'video.processing.dlq',
        'video.status-updates',
        'video.status-updates.retry',
        'video.status-updates.dlq'
    )
    $expectedExchanges = @(
        'video.processing.exchange',
        'video.processing.retry.exchange',
        'video.processing.dlx',
        'video.events',
        'video.status.retry.exchange',
        'video.status.dlx'
    )
    Assert-SetEquals -Expected $expectedQueues -Actual ([string[]]@($rabbit.queues | ForEach-Object { $_.name })) -Name 'RabbitMQ queues'
    Assert-SetEquals -Expected $expectedExchanges -Actual ([string[]]@($rabbit.exchanges | ForEach-Object { $_.name })) -Name 'RabbitMQ exchanges'
    Assert-True (@($rabbit.policies).Count -eq 4) 'RabbitMQ must keep the four expected DLX/retry policies.'

    foreach ($queue in @($rabbit.queues)) {
        Assert-True ($queue.durable -eq $true) "RabbitMQ queue $($queue.name) must be durable."
        Assert-True ($queue.arguments.'x-queue-type' -eq 'quorum') "RabbitMQ queue $($queue.name) must be quorum."
    }

    $realm = Read-JsonFile -Path (Join-Path $RepoRoot 'keycloak/fiapx-realm.json')
    Assert-True ($realm.realm -eq 'fiapx') 'Keycloak realm must be fiapx.'
    Assert-SetEquals -Expected @('fiapx-postman', 'video-management-service') -Actual ([string[]]@($realm.clients | ForEach-Object { $_.clientId })) -Name 'Keycloak clients'
    Assert-SetEquals -Expected @('usertest1', 'usertest2') -Actual ([string[]]@($realm.users | ForEach-Object { $_.username })) -Name 'Keycloak DEMO users'
    foreach ($user in @($realm.users)) {
        Assert-True ($user.email -eq "$($user.username)@fiapx.local") "Keycloak user $($user.username) must use the fiapx.local DEMO e-mail."
        Assert-True (@($user.credentials).Count -eq 1) "Keycloak user $($user.username) must have exactly one DEMO credential."
        Assert-True ($user.credentials[0].temporary -eq $false) "Keycloak user $($user.username) password must not be temporary."
    }

    $baseConfig = Invoke-ComposeJson -ComposeFiles @('docker-compose.yml')
    $expectedServices = @(
        'keycloak',
        'postgres',
        'redis',
        'mailpit',
        'rabbitmq',
        'minio',
        'minio-init',
        'video-management-migrations',
        'video-management-service',
        'video-processing-service'
    )
    Assert-SetEquals -Expected $expectedServices -Actual ([string[]]@($baseConfig.services.PSObject.Properties.Name)) -Name 'Compose services'
    Assert-SetEquals -Expected @('postgres-data', 'redis-data', 'minio-data', 'minio-events', 'rabbitmq-data') -Actual ([string[]]@($baseConfig.volumes.PSObject.Properties.Name)) -Name 'Compose volumes'

    foreach ($service in @($baseConfig.services.PSObject.Properties)) {
        Assert-True ($null -eq $service.Value.PSObject.Properties['build']) "Compose base must be image-only. Service has build: $($service.Name)"
        Assert-ImageReference -Service $service.Name -Image $service.Value.image
    }

    $managementImage = $baseConfig.services.'video-management-service'.image
    $processingImage = $baseConfig.services.'video-processing-service'.image
    Assert-True ($managementImage -eq $envExample['VIDEO_MANAGEMENT_IMAGE']) 'video-management-service must resolve from VIDEO_MANAGEMENT_IMAGE.'
    Assert-True ($baseConfig.services.'video-management-migrations'.image -eq $envExample['VIDEO_MANAGEMENT_IMAGE']) 'video-management-migrations must resolve from VIDEO_MANAGEMENT_IMAGE.'
    Assert-True ($processingImage -eq $envExample['VIDEO_PROCESSING_IMAGE']) 'video-processing-service must resolve from VIDEO_PROCESSING_IMAGE.'

    [void](Invoke-ComposeJson -ComposeFiles @('docker-compose.yml', 'docker-compose.dev.yml'))

    Write-Host 'Infra validation PASS.'
}
finally {
    Pop-Location
}
