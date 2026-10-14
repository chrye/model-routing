[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$GatewayUrl,

    [string]$SubscriptionKey = $env:APIM_SUBSCRIPTION_KEY,

    # Which phases to run: "all" (the default), or a comma-separated list such as "1", "2", "3" or "1,3".
    #   1 = weighted baseline, 2 = pressure burst through APIM, 3 = guaranteed traveler,
    #   4 = backend 4: PTU -> Foundry-native spillover (separate from the pool).
    [string]$Phase = "all",

    # Phase 1: small concurrent requests. A few hundred are needed to see the 53/47 split.
    [ValidateRange(0, 10000)]
    [int]$WeightedRequestCount = 200,

    # Phase 2: large unique prompts sent through APIM that saturate the 15-PTU deployments organically.
    [ValidateRange(0, 64)]
    [int]$PressureRequestCount = 16,

    # Phase 2: small requests spread across the first seconds of that burst.
    [ValidateRange(0, 100)]
    [int]$SmallRequestCount = 24,

    [ValidateRange(1, 60)]
    [int]$SmallSpreadSeconds = 6,

    # Prompt size is PromptRepeat x ~10 tokens.
    [ValidateRange(1000, 25000)]
    [int]$PromptRepeat = 9000,

    # Phase 3: how many times to saturate the PTUs and send a tracer, stopping as soon as the tracer
    # walks backend 1 -> 2 -> 3. The first hop is weighted, so a tracer can also walk 2 -> 1 -> 3.
    [ValidateRange(0, 10)]
    [int]$TravelerCycles = 6,

    [ValidateRange(1, 20)]
    [int]$PrimeRequestsPerBackend = 6,

    [ValidateRange(1000, 25000)]
    [int]$PrimePromptRepeat = 15000,

    # Phase 4: rounds of saturating backend 4's PTU directly, and small requests per round sent through APIM.
    [ValidateRange(1, 10)]
    [int]$SpilloverRounds = 3,

    [ValidateRange(1, 50)]
    [int]$SpilloverRequestsPerRound = 12
)

if ([string]::IsNullOrWhiteSpace($SubscriptionKey)) {
    throw "Provide -SubscriptionKey or set the APIM_SUBSCRIPTION_KEY environment variable."
}

$selectedPhases = if ($Phase.Trim() -eq "all") { @("1", "2", "3", "4") } else { @($Phase -split "[,\s]+" | Where-Object { $_ }) }
$unknownPhases = @($selectedPhases | Where-Object { $_ -notin "1", "2", "3", "4" })
if ($selectedPhases.Count -eq 0 -or $unknownPhases.Count -gt 0) {
    throw "Unknown -Phase '$Phase'. Use 'all' or a comma-separated list of 1, 2, 3 and 4, for example '1' or '1,3'."
}
$runPhase1 = "1" -in $selectedPhases
$runPhase2 = "2" -in $selectedPhases
$runPhase3 = "3" -in $selectedPhases
$runPhase4 = "4" -in $selectedPhases
Write-Host "Running phase(s): $(($selectedPhases | Sort-Object -Unique) -join ', ')"
Write-Host ""

function Get-Outcome($result) {
    $hops = @($result.Path -split ">" | Where-Object { $_ }).Count
    $last = ($result.Path -split ">")[-1]
    if ($result.Status -eq 200) {
        if ($hops -le 1 -and $last -eq "route-backend-3") { return "200 from backend 3 directly (both priority-1 breakers were already open)" }
        if ($hops -le 1 -and $result.SpilloverFrom) { return "200 after PTU 429 -> native TPM spillover (APIM not involved)" }
        if ($hops -le 1) { return "200 from the first backend's PTU" }
        if ($hops -eq 2 -and $last -eq "route-backend-3") { return "200 on backend 3 after one failed attempt (other breaker was already open)" }
        if ($hops -eq 2) { return "200 after APIM retried on the other priority-1 backend" }
        return "200 after trying both priority-1 backends, then backend 3"
    }
    if ($result.Status -eq 429) { return "429 returned to caller after $hops attempt(s)" }
    return "Status $($result.Status) after $hops attempt(s)"
}

function Format-Path($path) {
    if (-not $path) { return "unknown" }
    return (($path -split ">") | ForEach-Object { $_ -replace "route-backend-", "backend " }) -join " -> "
}

# Phases 3 and 4 call the Foundry accounts directly. Fail clearly when this machine cannot resolve the account's host name.
function Test-FoundryEndpoint($target) {
    $hostName = ([uri]$target.endpoint).Host
    foreach ($try in 1..5) {
        try { [void][System.Net.Dns]::GetHostAddresses($hostName); return $true }
        catch { Start-Sleep -Seconds 1 }
    }
    Write-Warning "Cannot resolve $hostName from this machine. The Foundry account exists, but the local DNS resolver is returning errors, which happens on networks with DNS filtering, especially for newly created account names. Wait a few minutes or run 'ipconfig /flushdns', then run again."
    return $false
}

$failures = 0
$traveler = $null
$rejected = $null

if ($runPhase1 -and $WeightedRequestCount -gt 0) {
    Write-Host "Phase 1: sending $WeightedRequestCount small requests (8 concurrent) through the 53/47 pool..."
    $weighted = 1..$WeightedRequestCount | ForEach-Object -ThrottleLimit 8 -Parallel {
        $id = "weighted-$([guid]::NewGuid())"
        $body = @{
            model = "gpt-5-mini"
            messages = @(@{ role = "user"; content = "Reply with only the word routed." })
            max_completion_tokens = 32
            reasoning_effort = "minimal"
        } | ConvertTo-Json -Depth 5 -Compress
        $headers = @{ "api-key" = $using:SubscriptionKey; "Content-Type" = "application/json"; "x-client-request-id" = $id }
        try {
            $response = Invoke-WebRequest -Uri $using:GatewayUrl -Method Post -Headers $headers -Body $body -SkipHttpErrorCheck -TimeoutSec 120
            [pscustomobject]@{ Id = $id; Status = [int]$response.StatusCode; Content = $response.Content }
        }
        catch {
            [pscustomobject]@{ Id = $id; Status = 0; Content = $_.Exception.Message }
        }
    }
    $succeeded = @($weighted | Where-Object { $_.Status -eq 200 }).Count
    $failures = $WeightedRequestCount - $succeeded
    Write-Host "Weighted requests: $succeeded succeeded, $failures failed."
    $weighted | Where-Object { $_.Status -ne 200 } | Select-Object -First 3 | ForEach-Object {
        Write-Warning "Request $($_.Id) returned $($_.Status): $($_.Content)"
    }
}

$pressureRan = $false
if ($runPhase2 -and ($PressureRequestCount + $SmallRequestCount) -gt 0) {
    $pressureRan = $true
    Write-Host ""
    Write-Host "Phase 2: pressure burst through APIM ($PressureRequestCount large prompts + $SmallRequestCount small requests over $SmallSpreadSeconds s)..."
    # A unique prefix on every prompt prevents prompt caching from discounting the PTU load.
    $filler = "The quick brown fox jumps over the lazy dog. " * $PromptRepeat
    $workItems = @()
    1..$PressureRequestCount | ForEach-Object { $workItems += [pscustomobject]@{ Kind = "pressure"; DelayMs = 0 } }
    for ($i = 0; $i -lt $SmallRequestCount; $i++) {
        $workItems += [pscustomobject]@{ Kind = "small"; DelayMs = 300 + [int]($i * $SmallSpreadSeconds * 1000 / $SmallRequestCount) }
    }

    $results = $workItems | ForEach-Object -ThrottleLimit $workItems.Count -Parallel {
        $id = "$($_.Kind)-$([guid]::NewGuid())"
        Start-Sleep -Milliseconds $_.DelayMs
        $isPressure = $_.Kind -eq "pressure"
        $content = if ($isPressure) { "[$id] $($using:filler) Reply with only the word ok." } else { "Reply with only the word routed." }
        $body = @{
            model = "gpt-5-mini"
            messages = @(@{ role = "user"; content = $content })
            max_completion_tokens = 32
            reasoning_effort = "minimal"
        } | ConvertTo-Json -Depth 5 -Compress
        $headers = @{ "api-key" = $using:SubscriptionKey; "Content-Type" = "application/json"; "x-client-request-id" = $id }
        try {
            $response = Invoke-WebRequest -Uri $using:GatewayUrl -Method Post -Headers $headers -Body $body -SkipHttpErrorCheck -TimeoutSec 170
            [pscustomobject]@{
                Id = $id
                Status = [int]$response.StatusCode
                Path = if ($response.Headers.ContainsKey("x-routing-path")) { $response.Headers["x-routing-path"] -join "" } else { "" }
                SpilloverFrom = if ($response.Headers.ContainsKey("x-ms-spillover-from-deployment")) { $response.Headers["x-ms-spillover-from-deployment"] -join "," } else { "" }
            }
        }
        catch {
            [pscustomobject]@{ Id = $id; Status = 0; Path = ""; SpilloverFrom = "" }
        }
    }

    $results | ForEach-Object { Get-Outcome $_ } | Group-Object | Sort-Object Name | ForEach-Object {
        Write-Host ("  {0,3}  {1}" -f $_.Count, $_.Name)
    }
    $traveler = $results | Where-Object { @($_.Path -split ">").Count -ge 3 -and $_.Status -eq 200 } | Select-Object -First 1
    # A request that used all of its attempts and still got a 429. Prefer one that reached three different backends.
    $rejected = $results |
        Where-Object { $_.Status -eq 429 -and @($_.Path -split ">" | Where-Object { $_ }).Count -ge 3 } |
        Sort-Object { @($_.Path -split ">" | Where-Object { $_ } | Select-Object -Unique).Count } -Descending |
        Select-Object -First 1
}

$allTargets = @()
if ($env:FOUNDRY_PRIME_TARGETS) { $allTargets = @($env:FOUNDRY_PRIME_TARGETS | ConvertFrom-Json) }
# Phase 3 saturates the two pooled PTU backends. Phase 4 uses backend 4 on its own.
$targets = @($allTargets | Where-Object { $_.name -in "route-backend-1", "route-backend-2" })
$spilloverTarget = $allTargets | Where-Object { $_.name -eq "route-backend-4" } | Select-Object -First 1

if ($runPhase3 -and $TravelerCycles -gt 0 -and $targets.Count -gt 0) {
    Write-Host ""
    Write-Host "Phase 3: saturating both PTUs directly (like another consumer of the same resources), then sending one tracer through APIM..."
    $primeFiller = "The quick brown fox jumps over the lazy dog. " * $PrimePromptRepeat
    foreach ($target in $targets) { [void](Test-FoundryEndpoint $target) }
    $best = $null
    for ($cycle = 1; $cycle -le $TravelerCycles; $cycle++) {
        if ($pressureRan -or $cycle -gt 1) {
            Write-Host "  Waiting 45 s for the circuit breakers to reset..."
            Start-Sleep -Seconds 45
        }

        # Priming requests go straight to the Foundry accounts, so APIM's circuit breakers stay closed.
        $primeItems = foreach ($target in $targets) { 1..$PrimeRequestsPerBackend | ForEach-Object { $target } }
        $primeJob = $primeItems | ForEach-Object -ThrottleLimit $primeItems.Count -Parallel {
            $id = "prime-$([guid]::NewGuid())"
            try {
                $body = @{ model = "gpt-5-mini"; messages = @(@{ role = "user"; content = "[$id] $($using:primeFiller) Reply with only the word ok." }); max_completion_tokens = 32; reasoning_effort = "minimal" } | ConvertTo-Json -Depth 5 -Compress
                $headers = @{ "Authorization" = "Bearer $($_.token)"; "Content-Type" = "application/json" }
                $uri = $_.endpoint.TrimEnd("/") + "/openai/v1/chat/completions"
                [int](Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $body -SkipHttpErrorCheck -TimeoutSec 170).StatusCode
            }
            catch { 0 }
        } -AsJob

        # A PTU only saturates a few seconds after the priming starts, and only for a few seconds.
        # A small direct request that spills over proves the PTU is saturated, so probe until both are.
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $saturatedAfter = $null
        while ($timer.Elapsed.TotalSeconds -lt 25) {
            $probes = $targets | ForEach-Object -ThrottleLimit $targets.Count -Parallel {
                try {
                    $body = @{ model = "gpt-5-mini"; messages = @(@{ role = "user"; content = "Reply with only the word ok." }); max_completion_tokens = 32; reasoning_effort = "minimal" } | ConvertTo-Json -Depth 5 -Compress
                    $headers = @{ "Authorization" = "Bearer $($_.token)"; "Content-Type" = "application/json" }
                    $uri = $_.endpoint.TrimEnd("/") + "/openai/v1/chat/completions"
                    (Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $body -SkipHttpErrorCheck -TimeoutSec 30).Headers.ContainsKey("x-ms-spillover-from-deployment")
                }
                catch { $false }
            }
            if (@($probes | Where-Object { $_ }).Count -eq $targets.Count) { $saturatedAfter = [math]::Round($timer.Elapsed.TotalSeconds, 1); break }
            Start-Sleep -Milliseconds 250
        }

        # 2000 reserved tokens exceed the 1K-TPM spillover quota, so a PTU 429 cannot be rescued by spillover.
        $tracerId = "tracer-$([guid]::NewGuid())"
        $tracerBody = @{ model = "gpt-5-mini"; messages = @(@{ role = "user"; content = "Reply with only the word routed." }); max_completion_tokens = 2000; reasoning_effort = "minimal" } | ConvertTo-Json -Depth 5 -Compress
        $tracerHeaders = @{ "api-key" = $SubscriptionKey; "Content-Type" = "application/json"; "x-client-request-id" = $tracerId }
        $tracer = [pscustomobject]@{ Id = $tracerId; Status = 0; Path = "" }
        try {
            $response = Invoke-WebRequest -Uri $GatewayUrl -Method Post -Headers $tracerHeaders -Body $tracerBody -SkipHttpErrorCheck -TimeoutSec 120
            $tracer.Status = [int]$response.StatusCode
            if ($response.Headers.ContainsKey("x-routing-path")) { $tracer.Path = $response.Headers["x-routing-path"] -join "" }
        }
        catch { }

        $primeStatuses = @(Receive-Job $primeJob -Wait -AutoRemoveJob)
        $primeSummary = ($primeStatuses | Group-Object | Sort-Object Name | ForEach-Object { "$($_.Count) x $($_.Name)" }) -join ", "
        $saturation = if ($null -ne $saturatedAfter) { "both PTUs saturated after $saturatedAfter s" } else { "PTUs did not both saturate" }
        Write-Host ("  Cycle {0}: {1}; priming responses [{2}]. Tracer: {3}, status {4}" -f $cycle, $saturation, $primeSummary, (Format-Path $tracer.Path), $tracer.Status)
        if (@($primeStatuses | Where-Object { $_ -in 401, 403 }).Count -gt 0) {
            Write-Warning "Priming requests were not authorized (401/403). The signed-in identity needs the Cognitive Services OpenAI User role on the Foundry accounts."
        }
        if (@($primeStatuses | Where-Object { $_ -eq 0 }).Count -gt 0) {
            Write-Warning "$(@($primeStatuses | Where-Object { $_ -eq 0 }).Count) priming request(s) never reached Foundry, usually a DNS or network problem on this machine, so the PTUs may not have saturated."
        }

        $hops = @($tracer.Path -split ">" | Where-Object { $_ }).Count
        if ($tracer.Status -eq 200 -and $hops -ge 3) {
            if (-not $best) { $best = $tracer }
            if ($tracer.Path -eq "route-backend-1>route-backend-2>route-backend-3") { $best = $tracer; break }
        }
    }
    if ($best) { $traveler = $best }
}
elseif ($runPhase3 -and $TravelerCycles -gt 0) {
    Write-Host ""
    Write-Host "Phase 3 skipped: set the FOUNDRY_PRIME_TARGETS environment variable (a JSON array of endpoint and token) to saturate the PTUs directly and guarantee a full-path request."
}

if ($runPhase2 -or $runPhase3) {
    Write-Host ""
    if ($traveler) {
        Write-Host "This request tried $(Format-Path $traveler.Path) and was answered with status $($traveler.Status)."
        Write-Host "Traveler request ID: $($traveler.Id)"
    }
    else {
        Write-Host "No request completed the full backend 1 -> 2 -> 3 path this run. Circuit breakers stay open for 30-60 seconds after a 429, so wait about a minute and run again."
    }
}

if ($runPhase2 -and $rejected) {
    $distinctBackends = @($rejected.Path -split ">" | Where-Object { $_ } | Select-Object -Unique).Count
    $label = if ($distinctBackends -ge 3) { "tried every backend but was rejected" } else { "used all of its attempts but was rejected" }
    Write-Host ""
    Write-Host "This request $label ($(Format-Path $rejected.Path), status 429)."
    Write-Host "Rejected request ID: $($rejected.Id)"
}

if ($runPhase4) {
    Write-Host ""
    if (-not $spilloverTarget) {
        Write-Host "Phase 4 skipped: FOUNDRY_PRIME_TARGETS has no route-backend-4 entry. Is backend 4 deployed?"
    }
    elseif (-not (Test-FoundryEndpoint $spilloverTarget)) {
        Write-Host "Phase 4 skipped: backend 4's endpoint cannot be resolved from this machine."
    }
    else {
        Write-Host "Phase 4: backend 4 PTU -> Foundry spillover. Another consumer saturates the PTU directly, then $SpilloverRequestsPerRound small requests per round go through APIM ($SpilloverRounds rounds)..."
        $directUri = $spilloverTarget.endpoint.TrimEnd("/") + "/openai/v1/chat/completions"
        $directHeaders = @{ "Authorization" = "Bearer $($spilloverTarget.token)"; "Content-Type" = "application/json" }
        $spillFiller = "The quick brown fox jumps over the lazy dog. " * $PrimePromptRepeat
        $probeBody = @{ model = "gpt-5-mini-ptu"; messages = @(@{ role = "user"; content = "Reply with only the word ok." }); max_completion_tokens = 32; reasoning_effort = "minimal" } | ConvertTo-Json -Depth 5 -Compress
        $spillResults = @()
        for ($round = 1; $round -le $SpilloverRounds; $round++) {
            if ($round -gt 1) { Start-Sleep -Seconds 5 }

            # Large unique prompts go straight to Foundry, so APIM never sees them. This is the PTU's other consumers.
            $primeJob = 1..$PrimeRequestsPerBackend | ForEach-Object -ThrottleLimit $PrimeRequestsPerBackend -Parallel {
                $id = "prime-$([guid]::NewGuid())"
                $body = @{ model = "gpt-5-mini-ptu"; messages = @(@{ role = "user"; content = "[$id] $($using:spillFiller) Reply with only the word ok." }); max_completion_tokens = 32; reasoning_effort = "minimal" } | ConvertTo-Json -Depth 5 -Compress
                # Retry only transient network errors, such as a failed DNS lookup on a flaky local resolver.
                $status = 0
                foreach ($try in 1..3) {
                    try { $status = [int](Invoke-WebRequest -Uri $using:directUri -Method Post -Headers $using:directHeaders -Body $body -SkipHttpErrorCheck -TimeoutSec 170).StatusCode; break }
                    catch { if ($_.Exception -isnot [System.Net.Http.HttpRequestException]) { break }; Start-Sleep -Milliseconds 500 }
                }
                $status
            } -AsJob

            # The PTU only saturates a few seconds after the priming starts. A small direct request that comes back with
            # the spillover header proves it, and it uses almost none of the spillover quota.
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $saturatedAfter = $null
            while ($timer.Elapsed.TotalSeconds -lt 25) {
                try { $spilled = (Invoke-WebRequest -Uri $directUri -Method Post -Headers $directHeaders -Body $probeBody -SkipHttpErrorCheck -TimeoutSec 30).Headers.ContainsKey("x-ms-spillover-from-deployment") }
                catch { $spilled = $false }
                if ($spilled) { $saturatedAfter = [math]::Round($timer.Elapsed.TotalSeconds, 1); break }
                Start-Sleep -Milliseconds 250
            }

            # The requests under test go through APIM. They are small, so the spillover quota is not used up.
            $burst = 1..$SpilloverRequestsPerRound | ForEach-Object -ThrottleLimit $SpilloverRequestsPerRound -Parallel {
                $id = "spill-$([guid]::NewGuid())"
                $body = @{ model = "gpt-5-mini-ptu"; messages = @(@{ role = "user"; content = "Reply with only the word routed." }); max_completion_tokens = 64; reasoning_effort = "minimal" } | ConvertTo-Json -Depth 5 -Compress
                $headers = @{ "api-key" = $using:SubscriptionKey; "Content-Type" = "application/json"; "x-client-request-id" = $id }
                # Retry only transient network errors (a request that failed before reaching APIM), never HTTP results or timeouts.
                $response = $null
                foreach ($try in 1..3) {
                    try { $response = Invoke-WebRequest -Uri $using:GatewayUrl -Method Post -Headers $headers -Body $body -SkipHttpErrorCheck -TimeoutSec 30; break }
                    catch { if ($_.Exception -isnot [System.Net.Http.HttpRequestException]) { break }; Start-Sleep -Milliseconds 500 }
                }
                if (-not $response) { return [pscustomobject]@{ Id = $id; Status = 0; Path = ""; SpilloverFrom = ""; ServedBy = ""; Tokens = 0 } }
                $tokens = 0
                try { $tokens = [int](($response.Content | ConvertFrom-Json).usage.total_tokens) } catch { }
                [pscustomobject]@{
                    Id = $id
                    Status = [int]$response.StatusCode
                    Path = if ($response.Headers.ContainsKey("x-routing-path")) { $response.Headers["x-routing-path"] -join "" } else { "" }
                    SpilloverFrom = if ($response.Headers.ContainsKey("x-ms-spillover-from-deployment")) { $response.Headers["x-ms-spillover-from-deployment"] -join "," } else { "" }
                    ServedBy = if ($response.Headers.ContainsKey("x-ms-deployment-name")) { $response.Headers["x-ms-deployment-name"] -join "," } else { "" }
                    Tokens = $tokens
                }
            }
            $primeStatuses = @(Receive-Job $primeJob -Wait -AutoRemoveJob)
            $spillResults += $burst

            $roundSpilled = @($burst | Where-Object { $_.Status -eq 200 -and $_.SpilloverFrom }).Count
            $roundPtu = @($burst | Where-Object { $_.Status -eq 200 -and -not $_.SpilloverFrom }).Count
            $roundRejected = @($burst | Where-Object { $_.Status -eq 429 }).Count
            $saturation = if ($null -ne $saturatedAfter) { "PTU saturated after $saturatedAfter s" } else { "PTU did not saturate" }
            $primeSummary = ($primeStatuses | Group-Object | Sort-Object Name | ForEach-Object { "$($_.Count) x $($_.Name)" }) -join ", "
            Write-Host ("  Round {0}: {1}; priming responses [{2}]. Through APIM: {3} served by spillover, {4} by the PTU, {5} x 429" -f $round, $saturation, $primeSummary, $roundSpilled, $roundPtu, $roundRejected)
            if (@($primeStatuses | Where-Object { $_ -eq 0 }).Count -gt 0) {
                Write-Warning "$(@($primeStatuses | Where-Object { $_ -eq 0 }).Count) priming request(s) never reached Foundry, usually a DNS or network problem on this machine, so the PTU may not have saturated."
            }
        }

        $spilledResults = @($spillResults | Where-Object { $_.Status -eq 200 -and $_.SpilloverFrom })
        $ptuResults = @($spillResults | Where-Object { $_.Status -eq 200 -and -not $_.SpilloverFrom })
        $rejectedResults = @($spillResults | Where-Object { $_.Status -eq 429 })
        $apimRetries = ($spillResults | ForEach-Object { [math]::Max(@($_.Path -split ">" | Where-Object { $_ }).Count - 1, 0) } | Measure-Object -Sum).Sum
        $spillTokens = ($spilledResults | Measure-Object -Property Tokens -Sum).Sum
        $spillNames = if ($spilledResults.Count -gt 0) { "$($spilledResults[0].SpilloverFrom) -> $($spilledResults[0].ServedBy)" } else { "gpt-5-mini-ptu -> gpt-5-mini-ptu-spillover" }

        Write-Host ""
        Write-Host "Phase 4 results ($($spillResults.Count) requests through APIM to backend 4):"
        Write-Host ("  {0,3}  200 served by the Foundry spillover deployment ({1})" -f $spilledResults.Count, $spillNames)
        Write-Host ("  {0,3}  200 served by the PTU deployment" -f $ptuResults.Count)
        Write-Host ("  {0,3}  429 (spillover quota exhausted)" -f $rejectedResults.Count)
        $otherResults = @($spillResults | Where-Object { $_.Status -ne 200 -and $_.Status -ne 429 })
        if ($otherResults.Count -gt 0) {
            Write-Host ("  {0,3}  other status ({1})" -f $otherResults.Count, (($otherResults | Group-Object Status | ForEach-Object { $_.Name }) -join ", "))
        }
        Write-Host "  APIM retries: $apimRetries (every request was a single APIM attempt)"
        Write-Host "  Spillover tokens used: $spillTokens"
        if ($rejectedResults.Count -gt 0) {
            Write-Warning "Some requests hit 429, so the spillover quota was exhausted. Lower -SpilloverRequestsPerRound or raise the spillover deployment's capacity in params.json."
        }
        Write-Host ""
        if ($spilledResults.Count -gt 0) {
            Write-Host "Spillover request ID: $($spilledResults[0].Id)"
        }
        else {
            Write-Host "No request was served by spillover, because the PTU was not saturated when they arrived. Run phase 4 again."
        }
    }
}

if ($failures -gt 0) {
    exit 1
}
