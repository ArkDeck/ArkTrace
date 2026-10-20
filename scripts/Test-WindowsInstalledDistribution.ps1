#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Archive,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ArchiveSha256,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ManifestSha256,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$SourceRevision,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$BuildHostFingerprint,
    [Parameter(Mandatory)][ValidateLength(1, 256)][string]$Publisher,
    [Parameter(Mandatory)][string]$WorkDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-HostFingerprint {
    $guid = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($guid))).ToLowerInvariant()
}

function Assert-CleanHostFacts([string[]]$Tools, [string[]]$Products, [string[]]$SdkRoots,
    [string]$HostFingerprint, [string]$BuildFingerprint) {
    if ($HostFingerprint -ceq $BuildFingerprint) { throw 'Acceptance must run on a different Windows installation from the build.' }
    if ($Tools.Count -ne 0 -or $Products.Count -ne 0 -or $SdkRoots.Count -ne 0) {
        throw 'Clean-host acceptance refuses installed Rust/MSVC/Windows SDK tools or VC++ redistributables.'
    }
}

function Get-CleanHostFacts {
    $tools = @('cargo', 'rustc', 'cl', 'link', 'dumpbin', 'signtool' | ForEach-Object {
        $command = Get-Command $_ -ErrorAction SilentlyContinue
        if ($command) { $command.Name }
    })
    $uninstall = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $products = @(Get-ItemProperty -Path $uninstall -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and
            $_.DisplayName -match 'Visual Studio|Visual C\+\+.*(Redistributable|Runtime)|Windows Software Development Kit|Rustup|Rust toolchain' } |
        ForEach-Object { $_.DisplayName })
    $sdkRoots = @('HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots',
        'HKLM:\SOFTWARE\Microsoft\VisualStudio\SxS\VS7',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\SxS\VS7' |
        Where-Object { Test-Path -LiteralPath $_ })
    return [pscustomobject]@{ tools = $tools; products = $products; sdkRoots = $sdkRoots }
}

function Assert-PhysicalPath([string]$Path) {
    if (-not [IO.Path]::IsPathFullyQualified($Path) -or $Path.StartsWith('\\')) { throw 'A local absolute path is required.' }
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Acceptance paths must not contain reparse points.'
            }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}

function Assert-ProductionManifest($Manifest, [string]$Revision, [string]$ExpectedPublisher) {
    if ($Manifest.schema -cne 'arktrace.cli-distribution.windows-x86_64/1' -or
        $Manifest.source.revision -cne $Revision -or $Manifest.source.dirty -isnot [bool] -or $Manifest.source.dirty -or
        $Manifest.signing.policy -cne 'authenticode-publisher' -or
        $Manifest.signing.publisher -cne $ExpectedPublisher -or
        $Manifest.signing.timestamped -isnot [bool] -or -not $Manifest.signing.timestamped) {
        throw 'Acceptance requires the exact clean source, production publisher and timestamped package.'
    }
}

function Get-SafeRelativePath([string]$Path) {
    if ($Path -cnotmatch '^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$' -or
        @($Path.Split('/') | Where-Object { $_ -in @('.', '..') -or $_.EndsWith('.') }).Count -ne 0) {
        throw 'Unsafe distribution member path.'
    }
    return $Path
}

function Assert-ProductionSignature($Signature) {
    if ($Signature.Status -ne 'Valid' -or $null -eq $Signature.SignerCertificate -or
        $Signature.SignerCertificate.Subject -eq $Signature.SignerCertificate.Issuer -or
        $null -eq $Signature.TimeStamperCertificate) {
        throw 'A trusted, timestamped, non-self-issued production signature is required.'
    }
}

function Write-PrivateRoot([string]$Path) {
    if (Test-Path -LiteralPath $Path) { throw 'Acceptance work directory must be absent.' }
    if (-not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($Path)) -PathType Container)) {
        throw 'Acceptance work parent must already exist.'
    }
    [void][IO.Directory]::CreateDirectory($Path)
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $owner = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.SetOwner($owner)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($owner, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl',
            'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Install-ExactArchive([string]$Path, [string]$Destination, [string]$ExpectedArchiveSha, [string]$ExpectedManifestSha,
    [string]$Revision, [string]$ExpectedPublisher) {
    $input = [IO.File]::Open($Path, 'Open', 'Read', 'Read')
    try {
        $archiveDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($input)).ToLowerInvariant()
        if ($archiveDigest -cne $ExpectedArchiveSha) { throw 'Distribution archive differs from the verified build.' }
        $input.Position = 0
    }
    catch { $input.Dispose(); throw }
    $zip = [IO.Compression.ZipArchive]::new($input, [IO.Compression.ZipArchiveMode]::Read)
    try {
        if ($zip.Entries.Count -gt 257 -or ($zip.Entries | Measure-Object Length -Sum).Sum -gt 2GB) {
            throw 'Distribution archive exceeds its closed bounds.'
        }
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $zip.Entries) {
            [void](Get-SafeRelativePath $entry.FullName)
            if (-not $names.Add($entry.FullName) -or $entry.Length -gt 512MB -or
                (($entry.ExternalAttributes -shr 16) -band 61440) -notin @(0, 32768)) {
                throw 'Distribution archive has a duplicate, oversized or non-regular member.'
            }
        }
        $manifestEntry = @($zip.Entries | Where-Object { $_.FullName -cmatch '^ArkTraceCLI-[A-Za-z0-9_.-]+/distribution-manifest.json$' })
        if ($manifestEntry.Count -ne 1 -or $manifestEntry[0].Length -gt 64KB) { throw 'Missing or oversized distribution manifest.' }
        $manifestStream = $manifestEntry[0].Open()
        $memory = [IO.MemoryStream]::new()
        try { $manifestStream.CopyTo($memory); $manifestBytes = $memory.ToArray() }
        finally { $manifestStream.Dispose(); $memory.Dispose() }
        $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($manifestBytes)).ToLowerInvariant()
        if ($digest -cne $ExpectedManifestSha) { throw 'Distribution manifest differs from the verified build.' }
        $manifest = [Text.Encoding]::UTF8.GetString($manifestBytes) | ConvertFrom-Json
        Assert-ProductionManifest $manifest $Revision $ExpectedPublisher
        $top = $manifestEntry[0].FullName.Split('/')[0]
        $expected = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        foreach ($fact in $manifest.integrity.files) {
            [void](Get-SafeRelativePath $fact.path)
            $expected.Add(($top + '/' + $fact.path), $fact)
        }
        $expected.Add($manifestEntry[0].FullName, [pscustomobject]@{ byteCount = $manifestBytes.Length; sha256 = $digest })
        if ($expected.Count -ne $zip.Entries.Count) { throw 'Distribution archive inventory is not closed.' }
        [void][IO.Directory]::CreateDirectory($Destination)
        foreach ($entry in $zip.Entries) {
            if (-not $expected.ContainsKey($entry.FullName)) { throw 'Undeclared distribution member.' }
            $fact = $expected[$entry.FullName]
            if ($entry.Length -ne $fact.byteCount) { throw 'Distribution member byte count differs.' }
            $target = Join-Path $Destination $entry.FullName
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            $source = $entry.Open()
            $output = [IO.File]::Open($target, 'CreateNew', 'Write', 'None')
            try { $source.CopyTo($output); $output.Flush($true) }
            finally { $source.Dispose(); $output.Dispose() }
            if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -cne $fact.sha256) {
                throw 'Distribution member hash differs.'
            }
        }
        return [pscustomobject]@{ root = (Join-Path $Destination $top); manifest = $manifest }
    }
    finally { $zip.Dispose(); $input.Dispose() }
}

function Invoke-InstalledCli([string]$Root, [string[]]$Arguments, [string]$CaptureRoot, [int]$Number) {
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $Root 'arktrace.exe'))
    $start.UseShellExecute = $false
    $start.WorkingDirectory = $CaptureRoot
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.RedirectStandardInput = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false, $true)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false, $true)
    $start.Environment.Clear()
    $windows = [IO.Directory]::GetParent([Environment]::SystemDirectory).FullName
    $start.Environment['SystemRoot'] = $windows
    $start.Environment['WINDIR'] = $windows
    $start.Environment['PATH'] = [Environment]::SystemDirectory
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Installed CLI did not start.' }
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit(180000)
        if ($timedOut) {
            $process.Kill($true)
            if (-not $process.WaitForExit(10000)) { throw 'Acceptance-owned process did not exit after its bounded stop.' }
        }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), 10000)) {
            throw 'Installed CLI output did not close within its drain budget.'
        }
        $out = $stdout.GetAwaiter().GetResult()
        $err = $stderr.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $CaptureRoot "$Number.stdout"), $out)
        [IO.File]::WriteAllText((Join-Path $CaptureRoot "$Number.stderr"), $err)
        if ($timedOut) { throw 'Installed CLI exceeded its acceptance deadline; original output retained privately.' }
        if ($process.ExitCode -ne 0 -or $err.Length -ne 0 -or $out.Length -gt 8388608) {
            throw "Installed CLI acceptance command $Number failed; original output retained privately."
        }
        return ($out | ConvertFrom-Json)
    }
    finally { $process.Dispose() }
}

function Assert-OwnedMove([string]$Source, [string]$Destination, [string]$WorkRoot) {
    $prefix = [IO.Path]::GetFullPath($WorkRoot).TrimEnd('\') + '\'
    foreach ($path in @($Source, $Destination)) {
        Assert-PhysicalPath $path
        if (-not [IO.Path]::GetFullPath($path).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Acceptance move escaped its private work directory.'
        }
    }
    if (Test-Path -LiteralPath $Destination) { throw 'Acceptance never overwrites a moved installation.' }
}

if (-not $IsWindows -or -not [Environment]::Is64BitProcess) { throw 'Native Windows x64 PowerShell is required.' }
Assert-PhysicalPath $Archive
Assert-PhysicalPath $WorkDirectory
$hostFingerprint = Get-HostFingerprint
$hostFacts = Get-CleanHostFacts
Assert-CleanHostFacts $hostFacts.tools $hostFacts.products $hostFacts.sdkRoots $hostFingerprint $BuildHostFingerprint
Write-PrivateRoot $WorkDirectory
$passed = $false
try {
    $installed = Install-ExactArchive $Archive (Join-Path $WorkDirectory 'Install Copy') $ArchiveSha256 $ManifestSha256 $SourceRevision $Publisher
    $root = $installed.root
    $manifest = $installed.manifest
    foreach ($relative in $manifest.integrity.executables) {
        Assert-ProductionSignature (Get-AuthenticodeSignature -LiteralPath (Join-Path $root $relative))
    }
    $captures = Join-Path $WorkDirectory 'captures'
    [void][IO.Directory]::CreateDirectory($captures)
    $doctorArgs = @('doctor', '--self-test', '--json', '--no-cache', '--timeout-ms', '120000', '--max-output-bytes', '262144')
    $doctor = Invoke-InstalledCli $root $doctorArgs $captures 1
    if ($doctor.tool.buildRevision -cne $manifest.tool.binarySHA256 -or
        @($doctor.result.checks | Where-Object { $_.status -cne 'ok' }).Count -ne 0 -or $doctor.result.checks.Count -ne 9) {
        throw 'Installed doctor did not prove all expected checks and the signed tool identity.'
    }
    $licenses = Invoke-InstalledCli $root @('licenses', '--json') $captures 2
    if ($licenses.result.licenseFiles.Count -ne 18 -or $licenses.result.rust.dependencyCount -ne 37) {
        throw 'Installed attribution differs from the reviewed distribution.'
    }
    $trace = Join-Path $root $manifest.layout.selfTestFixture
    $number = 2
    foreach ($command in @('summary', 'inspect', 'analyze')) {
        $arguments = @($command, '--json', '--no-cache', '--timeout-ms', '60000', '--max-rows', '1000',
            '--max-events', '10000', '--max-output-bytes', '8388608')
        if ($command -ceq 'analyze') { $arguments += @('--kind', 'cpu', '--threshold-ns', '1000000', '--limit', '20') }
        $number++
        $result = Invoke-InstalledCli $root ($arguments + @($trace)) $captures $number
        if ($null -eq $result.result -or $result.tool.buildRevision -cne $manifest.tool.binarySHA256 -or
            $result.trace.parser.binarySha256 -cne $manifest.traceStreamer.binarySHA256 -or
            $result.provenance.indexSchemaVersion -ne 4) { throw 'Installed trace command lost its pinned identity or provenance.' }
    }
    $moved = Join-Path $WorkDirectory 'Moved Install'
    Assert-OwnedMove $root $moved $WorkDirectory
    Move-Item -LiteralPath $root -Destination $moved -ErrorAction Stop
    $doctor = Invoke-InstalledCli $moved $doctorArgs $captures 6
    if ($doctor.tool.buildRevision -cne $manifest.tool.binarySHA256 -or $doctor.result.checks.Count -ne 9 -or
        @($doctor.result.checks | Where-Object { $_.status -cne 'ok' }).Count -ne 0) { throw 'Moved installed package failed doctor.' }
    $passed = $true
}
finally {
    $report = [ordered]@{
        schema = 'arktrace.windows-installed-acceptance/v1'
        passed = $passed
        sourceRevision = $SourceRevision
        archiveSha256 = $ArchiveSha256
        manifestSha256 = $ManifestSha256
        publisher = $Publisher
        cleanHost = $true
        hostFingerprint = $hostFingerprint
        buildHostFingerprint = $BuildHostFingerprint
        storageRootMode = 'known-folder'
        completedCommands = if ($passed) { 6 } else { $null }
        fixtureOnly = $true
        deviceAcceptanceClaim = $false
    }
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $WorkDirectory 'acceptance.json') -Encoding utf8NoBOM
}
Write-Output 'PASS production-signed Windows installed package on separate clean host (fixture workload; no device acceptance claim).'
