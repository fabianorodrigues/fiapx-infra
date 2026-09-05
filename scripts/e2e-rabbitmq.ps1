[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 240,
    [switch]$SkipBuild,
    [switch]$BootstrapUsers,
    [string]$EnvFile,
    [switch]$ImageOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$InfraRoot = Split-Path -Parent $PSScriptRoot
$Root = $InfraRoot
$InvocationRoot = (Get-Location).Path
$ComposeFile = Join-Path $InfraRoot "docker-compose.yml"
$DevComposeFile = Join-Path $InfraRoot "docker-compose.dev.yml"

function Resolve-E2EEnvFile {
    if (-not [string]::IsNullOrWhiteSpace($EnvFile)) {
        $candidate = $EnvFile
        if (-not [IO.Path]::IsPathRooted($candidate)) {
            $candidate = Join-Path $InvocationRoot $candidate
        }

        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Env file not found: $candidate"
        }

        return (Resolve-Path -LiteralPath $candidate).Path
    }

    $privateEnv = Join-Path $InfraRoot ".env"
    if (Test-Path -LiteralPath $privateEnv -PathType Leaf) {
        return (Resolve-Path -LiteralPath $privateEnv).Path
    }

    $exampleEnv = Join-Path $InfraRoot ".env.example"
    if (Test-Path -LiteralPath $exampleEnv -PathType Leaf) {
        return (Resolve-Path -LiteralPath $exampleEnv).Path
    }

    throw "No env file found. Create .env or keep .env.example in $InfraRoot."
}

function Import-DotEnv {
    param([Parameter(Mandatory = $true)][string]$Path)

    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }

        $separator = $line.IndexOf("=")
        if ($separator -le 0) {
            continue
        }

        $name = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        [Environment]::SetEnvironmentVariable($name, $value, "Process")
    }
}

$ResolvedEnvFile = Resolve-E2EEnvFile
Import-DotEnv $ResolvedEnvFile
Set-Location $InfraRoot

$script:ComposeArgs = @("--env-file", $ResolvedEnvFile, "-f", $ComposeFile)
if (-not $ImageOnly) {
    $script:ComposeArgs += @("-f", $DevComposeFile)
}

Write-Host "E2E using env file: $ResolvedEnvFile"
Write-Host "E2E compose mode: $(if ($ImageOnly) { 'image-only' } else { 'development' })"

$Evidence = [ordered]@{}
$TempRoots = New-Object System.Collections.Generic.List[string]

function Get-EnvOrDefault {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Default
    )

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }

    return $value
}

function Require-Env {
    param([Parameter(Mandatory = $true)][string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Environment variable $Name is required."
    }

    return $value
}

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function Invoke-ExternalOutput {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )

    $output = & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }

    return $output
}

function Invoke-Compose {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $composeArguments = @("compose") + $script:ComposeArgs + $Arguments
    Invoke-External docker @composeArguments
}

function Invoke-ComposeOutput {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $composeArguments = @("compose") + $script:ComposeArgs + $Arguments
    Invoke-ExternalOutput docker @composeArguments
}

function Wait-Until {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Condition,
        [int]$TimeoutSec = $TimeoutSeconds,
        [int]$IntervalMs = 1000
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
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

        Start-Sleep -Milliseconds $IntervalMs
    }

    if ($lastError) {
        throw "Timed out waiting for $Name. Last error: $lastError"
    }

    throw "Timed out waiting for $Name."
}

function Add-Evidence {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value
    )

    $script:Evidence[$Name] = $Value
    Write-Host "EVIDENCE $Name"
    $Value | ConvertTo-Json -Depth 20 | Write-Host
}

function New-BasicAuthHeader {
    param(
        [Parameter(Mandatory = $true)][string]$User,
        [Parameter(Mandatory = $true)][string]$Password
    )

    $token = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${User}:${Password}"))
    return @{ Authorization = "Basic $token" }
}

function ConvertTo-JsonBody {
    param($Body)

    if ($null -eq $Body) {
        return $null
    }

    return ($Body | ConvertTo-Json -Depth 40 -Compress)
}

function Invoke-Json {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        $Body = $null,
        [hashtable]$Headers = @{},
        [string]$ContentType = "application/json"
    )

    if ($null -eq $Body) {
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers
    }

    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -ContentType $ContentType -Body (ConvertTo-JsonBody $Body)
}

function UrlEncodeSegment {
    param([Parameter(Mandatory = $true)][string]$Value)
    return [Uri]::EscapeDataString($Value)
}

function Get-JsonProperty {
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-CollectionItems {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }

    $wrappedValue = Get-JsonProperty $Value "value"
    if ($null -ne $wrappedValue) {
        return @($wrappedValue)
    }

    return @($Value)
}

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Expected -ne [string]$Actual) {
        throw "$Message Expected=[$Expected] Actual=[$Actual]"
    }
}

$script:VideoManagementImage = Require-Env "VIDEO_MANAGEMENT_IMAGE"
$script:VideoProcessingImage = Require-Env "VIDEO_PROCESSING_IMAGE"
$KeycloakAdminUser = Require-Env "KEYCLOAK_ADMIN_USERNAME"
$KeycloakAdminPassword = Require-Env "KEYCLOAK_ADMIN_PASSWORD"
$E2EUser = Get-EnvOrDefault "FIAPX_E2E_USERTEST1_USERNAME" "usertest1"
$E2EPassword = Get-EnvOrDefault "FIAPX_E2E_USERTEST1_PASSWORD" "fiapx_usertest1_demo_password"
$RabbitUser = Get-EnvOrDefault "RABBITMQ_DEFAULT_USER" "fiapx"
$RabbitPassword = Get-EnvOrDefault "RABBITMQ_DEFAULT_PASS" "fiapx_dev_password"
$RabbitManagementPort = Get-EnvOrDefault "RABBITMQ_MANAGEMENT_PORT" "15672"
$VideoManagementPort = Get-EnvOrDefault "VIDEO_MANAGEMENT_PORT" "8080"
$KeycloakPort = Get-EnvOrDefault "KEYCLOAK_PORT" "8081"
$MinioApiPort = Get-EnvOrDefault "MINIO_API_PORT" "9000"
$MailpitWebPort = Get-EnvOrDefault "MAILPIT_WEB_PORT" "8025"
$MinioBucket = Get-EnvOrDefault "MINIO_BUCKET" "videos"
$VHost = Get-EnvOrDefault "RABBITMQ_VHOST" "/"

$RabbitBase = "http://localhost:$RabbitManagementPort/api"
$ApiBase = "http://localhost:$VideoManagementPort"
$KeycloakBase = "http://localhost:$KeycloakPort"
$MinioHealth = "http://localhost:$MinioApiPort/minio/health/ready"
$MailpitBase = "http://localhost:$MailpitWebPort"
$RabbitHeaders = New-BasicAuthHeader $RabbitUser $RabbitPassword
$EncodedVHost = UrlEncodeSegment $VHost

function Invoke-RabbitApi {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        $Body = $null
    )

    return Invoke-Json -Method $Method -Uri "$RabbitBase$Path" -Body $Body -Headers $RabbitHeaders
}

function Get-Queue {
    param([Parameter(Mandatory = $true)][string]$Name)
    return Invoke-RabbitApi Get "/queues/$EncodedVHost/$(UrlEncodeSegment $Name)"
}

function Get-QueueSample {
    param([Parameter(Mandatory = $true)][string]$Name)

    return @(Get-QueueSamples -Name $Name -Count 1) | Select-Object -First 1
}

function Get-QueueSamples {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$Count = 20
    )

    $body = @{
        count = $Count
        ackmode = "ack_requeue_true"
        encoding = "auto"
        truncate = 50000
    }

    $messages = Invoke-RabbitApi Post "/queues/$EncodedVHost/$(UrlEncodeSegment $Name)/get" $body
    return @($messages)
}

function Wait-QueueContainsVideoId {
    param(
        [Parameter(Mandatory = $true)][string]$Queue,
        [Parameter(Mandatory = $true)][string]$VideoId
    )

    return Wait-Until "$Queue contains $VideoId" {
        $messages = Get-QueueSamples -Name $Queue -Count 50
        $match = @($messages) | Where-Object {
            $payload = Get-JsonProperty $_ "payload"
            $payload -and $payload.Contains($VideoId)
        } | Select-Object -First 1

        if ($null -ne $match) {
            return $match
        }

        return $false
    }
}

function Wait-QueueContainsAllVideoIds {
    param(
        [Parameter(Mandatory = $true)][string]$Queue,
        [Parameter(Mandatory = $true)][string[]]$VideoIds
    )

    return Wait-Until "$Queue contains all expected video ids" {
        $messages = Get-QueueSamples -Name $Queue -Count 100
        $payloads = @($messages) | ForEach-Object { Get-JsonProperty $_ "payload" }
        foreach ($videoId in $VideoIds) {
            $found = $false
            foreach ($payload in $payloads) {
                if ($payload -and $payload.Contains($videoId)) {
                    $found = $true
                    break
                }
            }

            if (-not $found) {
                return $false
            }
        }

        return $messages
    }
}

function Wait-QueueMessagesAtLeast {
    param(
        [Parameter(Mandatory = $true)][string]$Queue,
        [Parameter(Mandatory = $true)][int]$Expected
    )

    return Wait-Until "$Queue messages >= $Expected" {
        $queueInfo = Get-Queue $Queue
        if ([int](Get-JsonProperty $queueInfo "messages") -ge $Expected) {
            return $queueInfo
        }

        return $false
    }
}

function Wait-QueueMessagesAtMost {
    param(
        [Parameter(Mandatory = $true)][string]$Queue,
        [Parameter(Mandatory = $true)][int]$Expected
    )

    return Wait-Until "$Queue messages <= $Expected" {
        $queueInfo = Get-Queue $Queue
        if ([int](Get-JsonProperty $queueInfo "messages") -le $Expected) {
            return $queueInfo
        }

        return $false
    }
}

function Wait-QueueConsumersAtLeast {
    param(
        [Parameter(Mandatory = $true)][string]$Queue,
        [Parameter(Mandatory = $true)][int]$Expected
    )

    return Wait-Until "$Queue consumers >= $Expected" {
        $queueInfo = Get-Queue $Queue
        if ([int](Get-JsonProperty $queueInfo "consumers") -ge $Expected) {
            return $queueInfo
        }

        return $false
    }
}

function Publish-RabbitMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Exchange,
        [Parameter(Mandatory = $true)][string]$RoutingKey,
        [Parameter(Mandatory = $true)][string]$Payload,
        [string]$MessageId = [Guid]::NewGuid().ToString("D"),
        [string]$CorrelationId = [Guid]::NewGuid().ToString("D"),
        [string]$Type = "e2e"
    )

    $body = @{
        properties = @{
            content_type = "application/json"
            delivery_mode = 2
            message_id = $MessageId
            correlation_id = $CorrelationId
            type = $Type
            headers = @{}
        }
        routing_key = $RoutingKey
        payload = $Payload
        payload_encoding = "string"
    }

    $result = Invoke-RabbitApi Post "/exchanges/$EncodedVHost/$(UrlEncodeSegment $Exchange)/publish" $body
    if (-not (Get-JsonProperty $result "routed")) {
        throw "RabbitMQ publish was unrouted. Exchange=$Exchange RoutingKey=$RoutingKey"
    }

    return $result
}

function Assert-RabbitTopology {
    $queuesWithPolicy = @(
        "video.processing",
        "video.processing.retry",
        "video.status-updates",
        "video.status-updates.retry"
    )

    $dlqs = @("video.processing.dlq", "video.status-updates.dlq")
    $allQueues = $queuesWithPolicy + $dlqs
    $queueEvidence = @{}

    foreach ($queueName in $allQueues) {
        $queue = Get-Queue $queueName
        Assert-Equal "quorum" (Get-JsonProperty $queue "type") "$queueName must be quorum."
        Assert-Equal "True" (Get-JsonProperty $queue "durable") "$queueName must be durable."

        $definition = Get-JsonProperty $queue "effective_policy_definition"
        $queueEvidence[$queueName] = @{
            type = Get-JsonProperty $queue "type"
            durable = Get-JsonProperty $queue "durable"
            effectivePolicy = $definition
        }

        if ($queuesWithPolicy -contains $queueName) {
            Assert-Equal "at-least-once" (Get-JsonProperty $definition "dead-letter-strategy") "$queueName dead-letter-strategy."
            Assert-Equal "reject-publish" (Get-JsonProperty $definition "overflow") "$queueName overflow."
            Assert-Equal "-1" (Get-JsonProperty $definition "delivery-limit") "$queueName delivery-limit."
        }
        else {
            if ($null -ne (Get-JsonProperty $definition "dead-letter-exchange")) {
                throw "$queueName must not have a dead-letter policy."
            }
        }
    }

    $policies = Get-CollectionItems (Invoke-RabbitApi Get "/policies/$EncodedVHost")
    foreach ($policy in $policies) {
        $pattern = Get-JsonProperty $policy "pattern"
        if ($pattern -match "dlq") {
            throw "DLQ policy is forbidden. Policy=$((Get-JsonProperty $policy 'name')) Pattern=$pattern"
        }
    }

    $bindings = Get-CollectionItems (Invoke-RabbitApi Get "/bindings/$EncodedVHost")
    $requiredBindings = @(
        @{ source = "video.processing.exchange"; destination = "video.processing"; routing_key = "video.uploaded" },
        @{ source = "video.processing.retry.exchange"; destination = "video.processing.retry"; routing_key = "video.uploaded" },
        @{ source = "video.processing.dlx"; destination = "video.processing.dlq"; routing_key = "video.processing.dlq" },
        @{ source = "video.events"; destination = "video.status-updates"; routing_key = "video.processing.started" },
        @{ source = "video.events"; destination = "video.status-updates"; routing_key = "video.processing.completed" },
        @{ source = "video.events"; destination = "video.status-updates"; routing_key = "video.processing.failed" },
        @{ source = "video.status.retry.exchange"; destination = "video.status-updates.retry"; routing_key = "video.processing.started" },
        @{ source = "video.status.retry.exchange"; destination = "video.status-updates.retry"; routing_key = "video.processing.completed" },
        @{ source = "video.status.retry.exchange"; destination = "video.status-updates.retry"; routing_key = "video.processing.failed" },
        @{ source = "video.status.dlx"; destination = "video.status-updates.dlq"; routing_key = "video.status.dlq" }
    )

    foreach ($required in $requiredBindings) {
        $match = @($bindings) | Where-Object {
            (Get-JsonProperty $_ "source") -eq $required.source -and
            (Get-JsonProperty $_ "destination") -eq $required.destination -and
            (Get-JsonProperty $_ "routing_key") -eq $required.routing_key
        } | Select-Object -First 1

        if ($null -eq $match) {
            throw "Required binding missing: $($required.source) $($required.routing_key) -> $($required.destination)"
        }
    }

    Add-Evidence "rabbitmq-topology" @{
        queues = $queueEvidence
        policies = @($policies)
        requiredBindings = $requiredBindings
    }
}

function Wait-HttpOk {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Uri
    )

    return Wait-Until $Name {
        $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 5
        if ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 300) {
            return $true
        }

        return $false
    }
}

function Wait-Rabbit {
    Wait-Until "RabbitMQ management API and imported definitions" {
        $overview = Invoke-RabbitApi Get "/overview"
        if ($null -eq $overview) {
            return $false
        }

        $policies = Get-CollectionItems (Invoke-RabbitApi Get "/policies/$EncodedVHost")
        $expectedPolicies = @(
            "fiapx-processing-main-at-least-once-dlx",
            "fiapx-processing-retry-at-least-once-dlx",
            "fiapx-status-main-at-least-once-dlx",
            "fiapx-status-retry-at-least-once-dlx"
        )

        foreach ($expectedPolicy in $expectedPolicies) {
            $found = $policies | Where-Object {
                (Get-JsonProperty $_ "name") -eq $expectedPolicy
            } | Select-Object -First 1

            if ($null -eq $found) {
                return $false
            }
        }

        $queuesWithPolicy = @(
            "video.processing",
            "video.processing.retry",
            "video.status-updates",
            "video.status-updates.retry"
        )

        foreach ($queueName in $queuesWithPolicy) {
            $queue = Get-Queue $queueName
            $definition = Get-JsonProperty $queue "effective_policy_definition"
            if ((Get-JsonProperty $definition "dead-letter-strategy") -ne "at-least-once") {
                return $false
            }
        }

        return $overview
    } | Out-Null
}

function Wait-ApiHealth {
    Wait-HttpOk "fiapx-video-management /health" "$ApiBase/health" | Out-Null
}

function Wait-MinioHealth {
    Wait-HttpOk "MinIO health" $MinioHealth | Out-Null
}

function ConvertFrom-Base64Url {
    param([Parameter(Mandatory = $true)][string]$Value)

    $padded = $Value.Replace("-", "+").Replace("_", "/")
    switch ($padded.Length % 4) {
        2 { $padded += "==" }
        3 { $padded += "=" }
    }

    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($padded))
}

function Get-AccessToken {
    param(
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$Password
    )

    $token = Wait-Until "Keycloak token for $Username" {
        $response = Invoke-RestMethod `
            -Method Post `
            -Uri "$KeycloakBase/realms/fiapx/protocol/openid-connect/token" `
            -ContentType "application/x-www-form-urlencoded" `
            -Body @{
                grant_type = "password"
                client_id = "fiapx-postman"
                username = $Username
                password = $Password
            }

        return $response.access_token
    }

    $claims = ConvertFrom-Json (ConvertFrom-Base64Url $token.Split(".")[1])
    return @{
        token = $token
        userId = $claims.sub
        username = $Username
    }
}

function Ensure-KeycloakUser {
    param(
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$Password
    )

    $adminToken = (Invoke-RestMethod `
        -Method Post `
        -Uri "$KeycloakBase/realms/master/protocol/openid-connect/token" `
        -ContentType "application/x-www-form-urlencoded" `
        -Body @{
            grant_type = "password"
            client_id = "admin-cli"
            username = $KeycloakAdminUser
            password = $KeycloakAdminPassword
        }).access_token

    $headers = @{ Authorization = "Bearer $adminToken" }
    $users = Invoke-RestMethod `
        -Method Get `
        -Uri "$KeycloakBase/admin/realms/fiapx/users?username=$(UrlEncodeSegment $Username)&exact=true" `
        -Headers $headers

    if (@($users).Count -eq 0) {
        Invoke-Json `
            -Method Post `
            -Uri "$KeycloakBase/admin/realms/fiapx/users" `
            -Headers $headers `
            -Body @{
                username = $Username
                enabled = $true
                email = "$Username@fiapx.local"
                emailVerified = $true
                firstName = $Username
                lastName = "FIAPX"
                requiredActions = @()
                credentials = @(@{
                    type = "password"
                    value = $Password
                    temporary = $false
                })
            } | Out-Null
    }
    else {
        $userId = @($users)[0].id
        Invoke-Json `
            -Method Put `
            -Uri "$KeycloakBase/admin/realms/fiapx/users/$userId" `
            -Headers $headers `
            -Body @{
                username = $Username
                enabled = $true
                email = "$Username@fiapx.local"
                emailVerified = $true
                firstName = $Username
                lastName = "FIAPX"
                requiredActions = @()
            } | Out-Null

        Invoke-Json `
            -Method Put `
            -Uri "$KeycloakBase/admin/realms/fiapx/users/$userId/reset-password" `
            -Headers $headers `
            -Body @{
                type = "password"
                value = $Password
                temporary = $false
            } | Out-Null
    }
}

function New-SyntheticMp4 {
    param([Parameter(Mandatory = $true)][string]$Name)

    $dir = Join-Path ([IO.Path]::GetTempPath()) "fiapx-e2e-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $dir | Out-Null
    $TempRoots.Add($dir)
    $fileName = "$Name.mp4"
    $path = Join-Path $dir $fileName

    Invoke-External docker run '--rm' `
        '--mount' "type=bind,source=$dir,target=/work" `
        '--entrypoint' ffmpeg `
        $script:VideoProcessingImage `
        '-hide_banner' '-loglevel' error '-y' `
        '-f' lavfi `
        '-i' "testsrc=duration=2:size=128x96:rate=10" `
        '-pix_fmt' yuv420p `
        "/work/$fileName"

    return $path
}

function New-InvalidMp4 {
    param([Parameter(Mandatory = $true)][string]$Name)

    $dir = Join-Path ([IO.Path]::GetTempPath()) "fiapx-e2e-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $dir | Out-Null
    $TempRoots.Add($dir)
    $path = Join-Path $dir "$Name.mp4"
    Set-Content -LiteralPath $path -Value "not an mp4" -NoNewline
    return $path
}

function New-Video {
    param(
        [Parameter(Mandatory = $true)]$Auth,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    return Invoke-Json `
        -Method Post `
        -Uri "$ApiBase/videos" `
        -Headers @{ Authorization = "Bearer $($Auth.token)" } `
        -Body @{
            fileName = $FileName
            contentType = "video/mp4"
        }
}

function Upload-Video {
    param(
        [Parameter(Mandatory = $true)]$Video,
        [Parameter(Mandatory = $true)][string]$Path
    )

    Invoke-WebRequest `
        -Method Put `
        -Uri $Video.uploadUrl `
        -ContentType "video/mp4" `
        -InFile $Path `
        -UseBasicParsing | Out-Null
}

function Get-Video {
    param(
        [Parameter(Mandatory = $true)]$Auth,
        [Parameter(Mandatory = $true)][string]$VideoId
    )

    return Invoke-RestMethod `
        -Method Get `
        -Uri "$ApiBase/videos/$VideoId" `
        -Headers @{ Authorization = "Bearer $($Auth.token)" }
}

function Wait-VideoStatus {
    param(
        [Parameter(Mandatory = $true)]$Auth,
        [Parameter(Mandatory = $true)][string]$VideoId,
        [Parameter(Mandatory = $true)][string]$Status
    )

    return Wait-Until "video $VideoId status $Status" {
        $video = Get-Video $Auth $VideoId
        if ($video.status -eq $Status) {
            return $video
        }

        return $false
    }
}

function Download-Zip {
    param(
        [Parameter(Mandatory = $true)]$Auth,
        [Parameter(Mandatory = $true)][string]$VideoId
    )

    $download = Invoke-RestMethod `
        -Method Get `
        -Uri "$ApiBase/videos/$VideoId/download" `
        -Headers @{ Authorization = "Bearer $($Auth.token)" }

    $dir = Join-Path ([IO.Path]::GetTempPath()) "fiapx-e2e-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $dir | Out-Null
    $TempRoots.Add($dir)
    $zipPath = Join-Path $dir "resultado.zip"
    Invoke-WebRequest -Method Get -Uri $download.downloadUrl -OutFile $zipPath -UseBasicParsing

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        if ($archive.Entries.Count -lt 1) {
            throw "Downloaded ZIP is empty."
        }
    }
    finally {
        $archive.Dispose()
    }

    return @{
        path = $zipPath
        bytes = (Get-Item -LiteralPath $zipPath).Length
    }
}

function Clear-Mailpit {
    try {
        Invoke-RestMethod -Method Delete -Uri "$MailpitBase/api/v1/messages" | Out-Null
    }
    catch {
        Write-Host "Mailpit clear failed: $($_.Exception.Message)"
    }
}

function Get-MailpitCount {
    $messages = Invoke-RestMethod -Method Get -Uri "$MailpitBase/api/v1/messages"
    $total = Get-JsonProperty $messages "total"
    if ($null -ne $total) {
        return [int]$total
    }

    $items = Get-JsonProperty $messages "messages"
    if ($null -ne $items) {
        return @($items).Count
    }

    if ($messages -is [array]) {
        return $messages.Count
    }

    return 0
}

function Wait-MailpitCount {
    param([Parameter(Mandatory = $true)][int]$Expected)

    return Wait-Until "Mailpit message count $Expected" {
        $count = Get-MailpitCount
        if ($count -eq $Expected) {
            return $count
        }

        return $false
    }
}

function Set-ProcessorScale {
    param([Parameter(Mandatory = $true)][int]$Scale)
    Invoke-Compose up '-d' '--force-recreate' '--scale' "video-processing-service=$Scale" video-processing-service
    if ($Scale -gt 0) {
        Wait-QueueConsumersAtLeast "video.processing" $Scale | Out-Null
    }
}

function New-MinioNotificationPayload {
    param(
        [Parameter(Mandatory = $true)][string]$UserId,
        [Parameter(Mandatory = $true)][string]$VideoId,
        [string]$EventName = "s3:ObjectCreated:Put"
    )

    $key = "videos/$UserId/$VideoId/original.mp4"
    return @{
        EventName = $EventName
        Key = $key
        Records = @(@{
            eventVersion = "2.0"
            eventSource = "minio:s3"
            awsRegion = ""
            eventTime = [DateTimeOffset]::UtcNow.ToString("O")
            eventName = $EventName
            s3 = @{
                s3SchemaVersion = "1.0"
                configurationId = "Config"
                bucket = @{
                    name = $MinioBucket
                    arn = "arn:aws:s3:::$MinioBucket"
                }
                object = @{
                    key = $key
                    size = 0
                    eTag = "e2e"
                    sequencer = "e2e"
                }
            }
        })
    } | ConvertTo-Json -Depth 20 -Compress
}

function Publish-ProcessingNotification {
    param(
        [Parameter(Mandatory = $true)][string]$UserId,
        [Parameter(Mandatory = $true)][string]$VideoId
    )

    $payload = New-MinioNotificationPayload -UserId $UserId -VideoId $VideoId
    Publish-RabbitMessage `
        -Exchange "video.processing.exchange" `
        -RoutingKey "video.uploaded" `
        -Payload $payload `
        -CorrelationId $VideoId `
        -Type "MinioObjectCreated" | Out-Null
}

function Publish-StatusEvent {
    param(
        [Parameter(Mandatory = $true)][string]$RoutingKey,
        [Parameter(Mandatory = $true)][string]$Payload,
        [Parameter(Mandatory = $true)][string]$VideoId,
        [Parameter(Mandatory = $true)][string]$Type
    )

    Publish-RabbitMessage `
        -Exchange "video.events" `
        -RoutingKey $RoutingKey `
        -Payload $Payload `
        -CorrelationId $VideoId `
        -Type $Type | Out-Null
}

function New-StartedEventPayload {
    param(
        [Parameter(Mandatory = $true)][string]$VideoId,
        [Parameter(Mandatory = $true)][string]$UserId
    )

    return @{
        eventId = [Guid]::NewGuid().ToString("D")
        videoId = $VideoId
        userId = $UserId
        occurredAt = [DateTimeOffset]::UtcNow.ToString("O")
    } | ConvertTo-Json -Depth 10 -Compress
}

function Get-MinioQueueDirEvidence {
    $output = Invoke-ComposeOutput exec '-T' minio sh '-c' "ls -laR /events/amqp-primary 2>/dev/null"
    return @($output)
}

function Wait-MinioQueueDirHasFiles {
    return Wait-Until "MinIO AMQP queue_dir files" {
        $files = Get-MinioQueueDirEvidence
        $eventFile = @($files) | Where-Object { $_ -like "*.event" } | Select-Object -First 1
        if ($eventFile) {
            return $files
        }

        return $false
    }
}

function Invoke-Success {
    param($Auth, [string]$ScenarioName)

    $videoFile = New-SyntheticMp4 $ScenarioName
    $created = New-Video $Auth "$ScenarioName.mp4"
    Upload-Video $created $videoFile
    $completed = Wait-VideoStatus $Auth $created.videoId "CONCLUIDO"
    $zip = Download-Zip $Auth $created.videoId

    Add-Evidence $ScenarioName @{
        videoId = $created.videoId
        status = $completed.status
        resultObjectKey = $completed.resultObjectKey
        zipBytes = $zip.bytes
    }

    return $completed
}

function Run-E2E {
    if ($ImageOnly -and -not $SkipBuild) {
        throw "Use -SkipBuild with -ImageOnly because docker-compose.yml is image-only."
    }

    if (-not $SkipBuild) {
        Invoke-Compose build video-management-service video-processing-service
    }

    Invoke-Compose up '-d' postgres redis mailpit rabbitmq minio keycloak
    Wait-Rabbit
    Wait-MinioHealth
    Wait-HttpOk "Keycloak realm" "$KeycloakBase/realms/fiapx" | Out-Null
    Invoke-Compose up minio-init
    Invoke-Compose up '-d' video-management-migrations video-management-service
    Wait-ApiHealth
    Invoke-Compose up '-d' '--force-recreate' '--scale' video-processing-service=1 video-processing-service
    Wait-QueueConsumersAtLeast "video.processing" 1 | Out-Null
    Assert-RabbitTopology

    if ($BootstrapUsers -or ((Get-EnvOrDefault "FIAPX_E2E_BOOTSTRAP_USERS" "false") -eq "true")) {
        Ensure-KeycloakUser $E2EUser $E2EPassword
    }

    $auth = Get-AccessToken $E2EUser $E2EPassword
    Add-Evidence "auth" @{ username = $E2EUser; userId = $auth.userId }

    Invoke-Success $auth "A-success" | Out-Null

    Clear-Mailpit
    $invalidFile = New-InvalidMp4 "B-terminal-failure"
    $processingDlqBefore = [int](Get-JsonProperty (Get-Queue "video.processing.dlq") "messages")
    $createdInvalid = New-Video $auth "B-terminal-failure.mp4"
    Upload-Video $createdInvalid $invalidFile
    $failedInvalid = Wait-VideoStatus $auth $createdInvalid.videoId "ERRO"
    $processingDlq = Wait-QueueMessagesAtLeast "video.processing.dlq" ($processingDlqBefore + 1)
    $mailCount = Wait-MailpitCount 1
    Add-Evidence "B-terminal-failure" @{
        videoId = $createdInvalid.videoId
        status = $failedInvalid.status
        processingDlqMessages = Get-JsonProperty $processingDlq "messages"
        mailpitMessages = $mailCount
    }

    Set-ProcessorScale 0
    $cFile = New-SyntheticMp4 "C-processing-retry-success"
    $cCreated = New-Video $auth "C-processing-retry-success.mp4"
    Upload-Video $cCreated $cFile
    Wait-QueueContainsVideoId "video.processing" $cCreated.videoId | Out-Null
    Invoke-Compose stop minio
    try {
        Set-ProcessorScale 1
        $retrySample = Wait-QueueContainsVideoId "video.processing.retry" $cCreated.videoId
    }
    finally {
        Invoke-Compose start minio
        Wait-MinioHealth
    }

    $cCompleted = Wait-VideoStatus $auth $cCreated.videoId "CONCLUIDO"
    Add-Evidence "C-processing-transient-retry-success" @{
        videoId = $cCreated.videoId
        status = $cCompleted.status
        retrySample = $retrySample
    }

    Set-ProcessorScale 0
    Clear-Mailpit
    $dFile = New-SyntheticMp4 "D-retries-exhausted"
    $dCreated = New-Video $auth "D-retries-exhausted.mp4"
    $processingDlqBefore = [int](Get-JsonProperty (Get-Queue "video.processing.dlq") "messages")
    Upload-Video $dCreated $dFile
    Wait-QueueContainsVideoId "video.processing" $dCreated.videoId | Out-Null
    Invoke-Compose stop minio
    try {
        Set-ProcessorScale 1
        $dFailed = Wait-VideoStatus $auth $dCreated.videoId "ERRO"
        $dDlq = Wait-QueueMessagesAtLeast "video.processing.dlq" ($processingDlqBefore + 1)
    }
    finally {
        Invoke-Compose start minio
        Wait-MinioHealth
    }

    Add-Evidence "D-retries-exhausted" @{
        videoId = $dCreated.videoId
        status = $dFailed.status
        processingDlqMessages = Get-JsonProperty $dDlq "messages"
    }

    Set-ProcessorScale 1
    $eCreated = New-Video $auth "E-404-terminal.mp4"
    $processingDlqBefore = [int](Get-JsonProperty (Get-Queue "video.processing.dlq") "messages")
    $retryBefore = [int](Get-JsonProperty (Get-Queue "video.processing.retry") "messages")
    Publish-ProcessingNotification $auth.userId $eCreated.videoId
    $eFailed = Wait-VideoStatus $auth $eCreated.videoId "ERRO"
    $eDlq = Wait-QueueMessagesAtLeast "video.processing.dlq" ($processingDlqBefore + 1)
    $retryAfter = [int](Get-JsonProperty (Get-Queue "video.processing.retry") "messages")
    if ($retryAfter -gt $retryBefore) {
        throw "404 terminal scenario unexpectedly produced processing retry."
    }

    Add-Evidence "E-404-terminal" @{
        videoId = $eCreated.videoId
        status = $eFailed.status
        processingDlqMessages = Get-JsonProperty $eDlq "messages"
        retryMessagesBefore = $retryBefore
        retryMessagesAfter = $retryAfter
    }

    Set-ProcessorScale 0
    $fVideos = New-Object System.Collections.Generic.List[object]
    $processingBefore = [int](Get-JsonProperty (Get-Queue "video.processing") "messages")
    foreach ($i in 1..4) {
        $file = New-SyntheticMp4 "F-backlog-$i"
        $created = New-Video $auth "F-backlog-$i.mp4"
        Upload-Video $created $file
        $fVideos.Add($created)
    }

    $fBacklog = Wait-QueueContainsAllVideoIds "video.processing" ([string[]]@($fVideos | ForEach-Object { $_.videoId }))
    Set-ProcessorScale 3
    foreach ($created in $fVideos) {
        Wait-VideoStatus $auth $created.videoId "CONCLUIDO" | Out-Null
    }
    $fDrained = Wait-QueueMessagesAtMost "video.processing" $processingBefore
    Add-Evidence "F-backlog" @{
        uploaded = $fVideos.Count
        backlogSamples = @($fBacklog).Count
        drainedMessages = Get-JsonProperty $fDrained "messages"
    }

    Invoke-Compose stop rabbitmq
    $healthWhileRabbitOff = Wait-HttpOk "Management API while RabbitMQ offline" "$ApiBase/health"
    $gFile = New-SyntheticMp4 "G-rabbitmq-offline"
    $gCreated = New-Video $auth "G-rabbitmq-offline.mp4"
    Upload-Video $gCreated $gFile
    $queueDirBeforeRestart = Wait-MinioQueueDirHasFiles
    Invoke-Compose restart minio
    Wait-MinioHealth
    $queueDirAfterRestart = Wait-MinioQueueDirHasFiles
    Invoke-Compose start rabbitmq
    Wait-Rabbit
    Assert-RabbitTopology
    $gCompleted = Wait-VideoStatus $auth $gCreated.videoId "CONCLUIDO"
    Add-Evidence "G-rabbitmq-offline-minio-event-store" @{
        apiHealthWhileRabbitOff = $healthWhileRabbitOff
        videoId = $gCreated.videoId
        status = $gCompleted.status
        queueDirBeforeMinioRestart = $queueDirBeforeRestart
        queueDirAfterMinioRestart = $queueDirAfterRestart
    }

    Set-ProcessorScale 0
    $hVideos = New-Object System.Collections.Generic.List[object]
    $processingBefore = [int](Get-JsonProperty (Get-Queue "video.processing") "messages")
    foreach ($i in 1..2) {
        $file = New-SyntheticMp4 "H-broker-restart-$i"
        $created = New-Video $auth "H-broker-restart-$i.mp4"
        Upload-Video $created $file
        $hVideos.Add($created)
    }

    $hBeforeRestart = Wait-QueueContainsAllVideoIds "video.processing" ([string[]]@($hVideos | ForEach-Object { $_.videoId }))
    Invoke-Compose restart rabbitmq
    Wait-Rabbit
    Assert-RabbitTopology
    $hAfterRestart = Wait-QueueContainsAllVideoIds "video.processing" ([string[]]@($hVideos | ForEach-Object { $_.videoId }))
    Set-ProcessorScale 1
    foreach ($created in $hVideos) {
        Wait-VideoStatus $auth $created.videoId "CONCLUIDO" | Out-Null
    }

    Add-Evidence "H-broker-restart-with-backlog" @{
        backlogSamplesBeforeRestart = @($hBeforeRestart).Count
        backlogSamplesAfterRestart = @($hAfterRestart).Count
        processed = $hVideos.Count
    }

    Set-ProcessorScale 3
    $iConsumers = Wait-QueueConsumersAtLeast "video.processing" 3
    $iVideos = New-Object System.Collections.Generic.List[object]
    foreach ($i in 1..6) {
        $file = New-SyntheticMp4 "I-multiple-processors-$i"
        $created = New-Video $auth "I-multiple-processors-$i.mp4"
        Upload-Video $created $file
        $iVideos.Add($created)
    }

    $iResults = foreach ($created in $iVideos) {
        Wait-VideoStatus $auth $created.videoId "CONCLUIDO"
    }

    $uniqueIds = @($iResults | Select-Object -ExpandProperty videoId -Unique).Count
    if ($uniqueIds -ne $iVideos.Count) {
        throw "Multiple processors scenario found duplicate video ids."
    }

    Add-Evidence "I-multiple-processors" @{
        consumers = Get-JsonProperty $iConsumers "consumers"
        uploaded = $iVideos.Count
        completed = @($iResults).Count
    }

    Set-ProcessorScale 1
    $jCreated = New-Video $auth "J-status-retry.mp4"
    $statusRetryBefore = [int](Get-JsonProperty (Get-Queue "video.status-updates.retry") "messages")
    $statusDlqBefore = [int](Get-JsonProperty (Get-Queue "video.status-updates.dlq") "messages")
    Invoke-Compose stop postgres
    try {
        $startedPayload = New-StartedEventPayload $jCreated.videoId $auth.userId
        Publish-StatusEvent `
            -RoutingKey "video.processing.started" `
            -Payload $startedPayload `
            -VideoId $jCreated.videoId `
            -Type "VideoProcessingStarted"
        $statusRetrySample = Wait-QueueContainsVideoId "video.status-updates.retry" $jCreated.videoId
    }
    finally {
        Invoke-Compose start postgres
    }

    Wait-ApiHealth
    $jProcessing = Wait-VideoStatus $auth $jCreated.videoId "PROCESSANDO"
    $statusDlqAfter = [int](Get-JsonProperty (Get-Queue "video.status-updates.dlq") "messages")
    if ($statusDlqAfter -ne $statusDlqBefore) {
        throw "Status retry success scenario unexpectedly sent a message to status DLQ."
    }

    Add-Evidence "J-status-transient-retry-success" @{
        videoId = $jCreated.videoId
        status = $jProcessing.status
        retrySample = $statusRetrySample
        statusDlqBefore = $statusDlqBefore
        statusDlqAfter = $statusDlqAfter
    }

    $kStatusDlqBefore = [int](Get-JsonProperty (Get-Queue "video.status-updates.dlq") "messages")
    Publish-StatusEvent `
        -RoutingKey "video.processing.completed" `
        -Payload "{not-json" `
        -VideoId ([Guid]::NewGuid().ToString("D")) `
        -Type "VideoProcessingCompleted"
    $kDlq = Wait-QueueMessagesAtLeast "video.status-updates.dlq" ($kStatusDlqBefore + 1)
    Add-Evidence "K-malformed-status-dlq" @{
        statusDlqBefore = $kStatusDlqBefore
        statusDlqAfter = Get-JsonProperty $kDlq "messages"
        sample = Get-QueueSample "video.status-updates.dlq"
    }
}

try {
    Run-E2E
    $artifactDir = Join-Path $Root "artifacts"
    New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
    $artifactPath = Join-Path $artifactDir "e2e-rabbitmq-results.json"
    $Evidence | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $artifactPath
    Write-Host "E2E RabbitMQ completed. Evidence: $artifactPath"
}
finally {
    try { Invoke-Compose start rabbitmq postgres minio | Out-Null } catch {}
    try { Invoke-Compose up '-d' '--force-recreate' '--scale' video-processing-service=1 video-processing-service | Out-Null } catch {}

    foreach ($tempRoot in $TempRoots) {
        if ($tempRoot -and $tempRoot.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $tempRoot)) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}
