$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$culture = [System.Globalization.CultureInfo]::InvariantCulture
function Emit([object[]]$Values) {
    $parts = foreach ($value in $Values) {
        if ($null -eq $value) { '' }
        elseif ($value -is [System.IFormattable]) { $value.ToString($null, $culture) }
        else { ([string]$value -replace '[\t\r\n]', ' ') }
    }
    [Console]::WriteLine(($parts -join "`t"))
}
[Console]::WriteLine('FARPORT_MONITOR_V1')
try {
    $os = Get-CimInstance Win32_OperatingSystem
    Emit @('uptime', ((Get-Date).ToUniversalTime() - $os.LastBootUpTime.ToUniversalTime()).TotalSeconds)
    Emit @('memory', ([double]$os.TotalVisibleMemorySize * 1024), ([double]($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) * 1024))
    if ($IncludeInfo) {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $system = Get-CimInstance Win32_ComputerSystem
        $user = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        Emit @('info', 'os', ($os.Caption + ' ' + $os.Version + ' (build ' + $os.BuildNumber + ')'))
        Emit @('info', 'kernel', $os.Version)
        Emit @('info', 'hostname', $system.Name)
        Emit @('info', 'model', ($system.Manufacturer + ' ' + $system.Model))
        Emit @('info', 'cpuModel', $cpu.Name)
        Emit @('info', 'logicalCPUs', $system.NumberOfLogicalProcessors)
        Emit @('info', 'architecture', $os.OSArchitecture)
        Emit @('info', 'username', $user.Name)
        Emit @('info', 'uid', $user.User.Value)
        Emit @('info', 'home', $env:USERPROFILE)
        Emit @('info', 'shell', ('PowerShell ' + $PSVersionTable.PSVersion.ToString()))
        $groups = foreach ($group in $user.Groups) { try { $group.Translate([System.Security.Principal.NTAccount]).Value } catch { $group.Value } }
        Emit @('info', 'groups', ($groups -join ', '))
    }
} catch { Emit @('warning', 'system-unavailable') }
try {
    $cpuUsage = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
    Emit @('cpuPercent', $cpuUsage.PercentProcessorTime)
} catch { Emit @('warning', 'cpu-unavailable') }
try {
    $processes = @(Get-Process)
    foreach ($process in ($processes | Select-Object -First 2000)) {
        $seconds = $null; $started = ''; $elapsed = $null
        try { $seconds = $process.TotalProcessorTime.TotalSeconds; $started = $process.StartTime.ToUniversalTime().Ticks.ToString(); $elapsed = ((Get-Date) - $process.StartTime).TotalSeconds } catch {}
        Emit @('process', $process.Id, '', $process.WorkingSet64, $seconds, $elapsed, $process.ProcessName, $started)
    }
    if ($processes.Count -gt 2000) { Emit @('warning', 'process-truncated') }
} catch { Emit @('warning', 'process-unavailable') }
try {
    foreach ($adapter in Get-NetAdapterStatistics) { Emit @('network', $adapter.Name, $adapter.ReceivedBytes, $adapter.SentBytes) }
} catch { Emit @('warning', 'network-unavailable') }
try {
    foreach ($disk in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3') { Emit @('disk', $disk.DeviceID, $disk.Size, ($disk.Size - $disk.FreeSpace), $disk.FreeSpace) }
} catch { Emit @('warning', 'disk-unavailable') }
try {
    $ports = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)
    foreach ($port in ($ports | Select-Object -First 4000)) { Emit @('port', 'TCP', ('[' + $port.LocalAddress + ']:' + $port.LocalPort), '*', 'LISTEN', $port.OwningProcess) }
    foreach ($port in (Get-NetUDPEndpoint -ErrorAction Stop | Select-Object -First 4000)) { Emit @('port', 'UDP', ('[' + $port.LocalAddress + ']:' + $port.LocalPort), '*', 'BOUND', $port.OwningProcess) }
    if ($ports.Count -gt 4000) { Emit @('warning', 'ports-truncated') }
} catch { Emit @('warning', 'ports-unavailable') }
Emit @('warning', 'process-scope')
Emit @('warning', 'port-owner-permissions')
Emit @('warning', 'process-user-unavailable')
Emit @('warning', 'process-bandwidth-unavailable')
