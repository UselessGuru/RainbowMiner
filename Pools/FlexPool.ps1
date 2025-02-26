﻿using module ..\Modules\Include.psm1

param(
    [PSCustomObject]$Wallets,
    [PSCustomObject]$Params,
    [alias("WorkerName")]
    [String]$Worker,
    [TimeSpan]$StatSpan,
    [String]$DataWindow = "avg",
    [Bool]$InfoOnly = $false,
    [Bool]$AllowZero = $false,
    [String]$StatAverage = "Minute_10",
    [String]$StatAverageStable = "Minute_10"
)

$Name = Get-Item $MyInvocation.MyCommand.Path | Select-Object -ExpandProperty BaseName

[hashtable]$Pool_RegionsTable = @{}

$Pool_Regions = @("us-east","us-west","de","se","sg","au","br","kr","hk","asia")
$Pool_Regions | Foreach-Object {$Pool_RegionsTable.$_ = Get-Region $_}

$Pools_Data = @(
    [PSCustomObject]@{symbol = "ETC";  ports = @(4444,5555); fee = 0.9; divisor = 1e18; stratum = "etc-%region%.flexpool.io"; regions = @("us-east","de","sg","asia"); altstratum = [PSCustomObject]@{asia="sgeetc.gfwroute.co"}}
    [PSCustomObject]@{symbol = "ZIL";  ports = @(4444,5555); fee = 0.9; divisor = 1e18; stratum = "zil.flexpool.io"; regions = @("us-east")}
)

$Pools_Data | Where-Object {$Pool_Currency = $_.symbol;$InfoOnly -or $Wallets.$Pool_Currency} | Foreach-Object {

    $Pool_User     = $Wallets.$Pool_Currency

    $Pool_Coin = Get-Coin $Pool_Currency
    $Pool_Algorithm_Norm = Get-Algorithm $Pool_Coin.Algo

    [hashtable]$Pool_FailoverStratumTable = @{}
    foreach($Pool_Region in $_.regions) {
        $Pool_FailoverRegions = @(Get-Region2 $Pool_RegionsTable.$Pool_Region | Where-Object {$Pool_RegionsTable.ContainsValue($_)})
        [array]::Reverse($Pool_FailoverRegions)
        $Pool_FailoverStratumTable.$Pool_Region = @(foreach ($Pool_FailoverRegion in @($Pool_Regions | Where-Object {$_ -ne $Pool_Region} | Sort-Object -Descending {$Pool_FailoverRegions.IndexOf($Pool_RegionsTable.$_)} | Select-Object -Unique -First 3)) {
            if ($_.altstratum.$Pool_FailoverRegion -ne $null) {$_.altstratum.$Pool_FailoverRegion} else {$_.stratum -replace "%region%",$Pool_FailoverRegion}
        })
    }

    if (-not $InfoOnly) {

        $Pool_HashRate = [PSCustomObject]@{}
        $Pool_Workers  = [PSCustomObject]@{}

        $ok = $false
        try {
            $Pool_HashRate = Invoke-RestMethodAsync "https://api.flexpool.io/v2/pool/hashrate?coin=$($Pool_Currency)" -tag $Name -cycletime 120
            $Pool_Workers = Invoke-RestMethodAsync "https://api.flexpool.io/v2/pool/workerCount?coin=$($Pool_Currency)" -tag $Name -cycletime 120
            $ok = -not $Pool_HashRate.error -and -not $Pool_Workers.error
        }
        catch {
            if ($Error.Count){$Error.RemoveAt(0)}
            Write-Log -Level Warn "$($_.Exception.Message)"
        }

        if (-not $ok) {
            Write-Log -Level Warn "Pool API ($Name) has failed. "
            return
        }

        $blocks = @()

        $page   = 0
        $number = 0
        do {
            $ok = $false
            try {
                $Pool_BlocksResult  = [PSCustomObject]@{}
                $Pool_BlocksResult = Invoke-RestMethodAsync "https://api.flexpool.io/v2/pool/blocks?coin=$($Pool_Currency)&page=$($page)" -retry 3 -retrywait 1000 -tag $Name -cycletime 180 -fixbigint

                $timestamp    = Get-UnixTimestamp
                $timestamp24h = $timestamp - 24*3600

                $ok = -not $Pool_BlocksResult.error -and (++$page -lt $Pool_BlocksResult.result.totalPages)
                if (-not $Pool_BlocksResult.error) {
                    $Pool_BlocksResult.result.data | Where-Object {$_.number -lt $number -or -not $number} | Foreach-Object {
                        if ($_.timestamp -gt $timestamp24h) {$blocks += $_.timestamp} else {$ok = $false}
                        $number = $_.number
                    }
                }
            }
            catch {
                if ($Error.Count){$Error.RemoveAt(0)}
            }
        } until (-not $ok)

        $timestamp    = Get-UnixTimestamp

        $blocks_measure = $blocks | Measure-Object -Minimum -Maximum
        $avgTime        = if ($blocks_measure.Count -gt 1) {($blocks_measure.Maximum - $blocks_measure.Minimum) / ($blocks_measure.Count - 1)} else {$timestamp}
        $Pool_BLK       = [int]$(if ($avgTime) {86400/$avgTime})
        $Pool_TSL       = $timestamp - ($blocks | Measure-Object -Maximum).Maximum

        $Stat = Set-Stat -Name "$($Name)_$($Pool_Currency)_Profit" -Value 0 -Duration $StatSpan -ChangeDetection $false -HashRate $Pool_HashRate.result.total -BlockRate $Pool_BLK -Quiet
        if (-not $Stat.HashRate_Live -and -not $AllowZero) {return}
    }

    foreach($Pool_Region in $_.regions) {
        $Pool_SSL = $false
        $Pool_Stratum = if ($_.altstratum.$Pool_Region -ne $null) {$_.altstratum.$Pool_Region} else {$_.stratum -replace "%region%",$Pool_Region}
        foreach($Pool_Port in $_.ports) {
            if ($Pool_Currency -ne "ZIL") {
                $Pool_Protocol = "stratum+$(if ($Pool_SSL) {"ssl"} else {"tcp"})"
                [PSCustomObject]@{
                    Algorithm     = $Pool_Algorithm_Norm
                    Algorithm0    = $Pool_Algorithm_Norm
                    CoinName      = $Pool_Coin.Name
                    CoinSymbol    = $Pool_Currency
                    Currency      = $Pool_Currency
                    Price         = 0
                    StablePrice   = 0
                    MarginOfError = 0
                    Protocol      = $Pool_Protocol
                    Host          = $Pool_Stratum
                    Port          = $Pool_Port
                    User          = "$($Pool_User).{workername:$Worker}"
                    Pass          = "x"
                    Region        = $Pool_RegionsTable.$Pool_Region
                    SSL           = $Pool_SSL
                    Updated       = $Stat.Updated
                    PoolFee       = $_.fee
                    Failover      = @($Pool_FailoverStratumTable.$Pool_Region | Foreach-Object {
                                        [PSCustomObject]@{
                                            Protocol = $Pool_Protocol
                                            Host     = $_
                                            Port     = $Pool_Port
                                            User     = "$($Pool_User).{workername:$Worker}"
                                            Pass     = "x"
                                        }
                                    })
                    DataWindow    = $DataWindow
                    Workers       = $Pool_Workers.result
                    Hashrate      = $Stat.HashRate_Live
                    BLK           = $Stat.BlockRate_Average
                    TSL           = $Pool_TSL
                    WTM           = $true
                    ErrorRatio    = $Stat.ErrorRatio
                    EthMode       = "ethproxy"
                    Name          = $Name
                    Penalty       = 0
                    PenaltyFactor = 1
                    Disabled      = $false
                    HasMinerExclusions = $false
                    Price_0       = 0.0
                    Price_Bias    = 0.0
                    Price_Unbias  = 0.0
                    Wallet        = $Pool_User
                    Worker        = "{workername:$Worker}"
                    Email         = $Email
                }
                [PSCustomObject]@{
                    Algorithm     = "$($Pool_Algorithm_Norm)FP"
                    Algorithm0    = "$($Pool_Algorithm_Norm)FP"
                    CoinName      = $Pool_Coin.Name
                    CoinSymbol    = $Pool_Currency
                    Currency      = $Pool_Currency
                    Price         = 0
                    StablePrice   = 0
                    MarginOfError = 0
                    Protocol      = $Pool_Protocol
                    Host          = $Pool_Stratum
                    Port          = $Pool_Port
                    User          = "$($Pool_User).{workername:$Worker}"
                    Pass          = "x"
                    Region        = $Pool_RegionsTable.$Pool_Region
                    SSL           = $Pool_SSL
                    Updated       = $Stat.Updated
                    PoolFee       = $_.fee
                    Failover      = @($Pool_FailoverStratumTable.$Pool_Region | Foreach-Object {
                                        [PSCustomObject]@{
                                            Protocol = $Pool_Protocol
                                            Host     = $_
                                            Port     = $Pool_Port
                                            User     = "$($Pool_User).{workername:$Worker}"
                                            Pass     = "x"
                                        }
                                    })
                    DataWindow    = $DataWindow
                    Workers       = $Pool_Workers.result
                    Hashrate      = $Stat.HashRate_Live
                    BLK           = $Stat.BlockRate_Average
                    TSL           = $Pool_TSL
                    WTM           = $true
                    ErrorRatio    = $Stat.ErrorRatio
                    EthMode       = "ethproxy"
                    Name          = $Name
                    Penalty       = 0
                    PenaltyFactor = 1
                    Disabled      = $false
                    HasMinerExclusions = $false
                    Price_0       = 0.0
                    Price_Bias    = 0.0
                    Price_Unbias  = 0.0
                    Wallet        = $Pool_User
                    Worker        = "{workername:$Worker}"
                    Email         = $Email
                }
            } elseif ($EnableBzminerDual -or $EnableGminerDual -or $EnableTeamblackDual -or $EnableRigelDual) {
                [PSCustomObject]@{
                    Algorithm     = "ZilliqaFP"
                    Algorithm0    = "ZilliqaFP"
                    CoinName      = "Zilliqa"
                    CoinSymbol    = "ZIL"
                    Currency      = "ZIL"
                    Price         = 1e-15
                    StablePrice   = 1e-15
                    MarginOfError = 0
                    Protocol      = "zmp"
                    Host          = "zil.flexpool.io"
                    Port          = $Pool_Port
                    User          = "$($Wallets.ZIL).{workername:$Worker}"
                    Pass          = "x"
                    Region        = $Pool_RegionsTable.$Pool_Region
                    SSL           = $Pool_Ssl
                    Updated       = (Get-Date).ToUniversalTime()
                    PoolFee       = 1.0
                    DataWindow    = $DataWindow
                    Workers       = $null
                    EthMode       = $Pool_EthProxy
                    Name          = $Name
                    Penalty       = 0
                    PenaltyFactor = 1
                    Disabled      = $false
                    HasMinerExclusions = $false
                    Price_0       = 0.0
                    Price_Bias    = 0.0
                    Price_Unbias  = 0.0
                    Wallet        = $Wallets.ZIL
                    Worker        = "{workername:$Worker}"
                    Email         = $Email
                }
            }
            $Pool_SSL = $true
        }
    }
}