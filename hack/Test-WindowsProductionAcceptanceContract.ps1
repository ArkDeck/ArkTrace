#Requires -Version 7.4
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Load helper definitions only. Synthetic archive/signature facts are never
# executed, signed, installed as a product or reported as production acceptance.
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'Test-WindowsInstalledDistribution.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw 'Installed acceptance script does not parse.' }
foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$script:passed = 0
function Check([string]$Name, [scriptblock]$Body) {
    & $Body
    $script:passed++
    Write-Output "PASS $Name"
}
function Refuses([scriptblock]$Body) {
    $refused = $false
    try { & $Body | Out-Null } catch { $refused = $true }
    if (-not $refused) { throw 'Expected a strict refusal.' }
}
function Manifest {
    return [pscustomobject]@{
        schema = 'arktrace.cli-distribution.windows-x86_64/1'
        source = [pscustomobject]@{ revision = ('a' * 40); dirty = $false }
        signing = [pscustomobject]@{ policy = 'authenticode-publisher'; publisher = 'Fixture publisher'; timestamped = $true }
    }
}
function Signature {
    return [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'Fixture leaf'; Issuer = 'Fixture issuer' }; TimeStamperCertificate = [pscustomobject]@{} }
}
Check 'separate clean installation admits helper preflight facts only' {
    Assert-CleanHostFacts @() @() @() ('a' * 64) ('b' * 64)
}
Check 'same installation refuses even with different runner labels' {
    Refuses { Assert-CleanHostFacts @() @() @() ('a' * 64) ('a' * 64) }
}
Check 'toolchain, VC++ runtime and SDK each refuse' {
    Refuses { Assert-CleanHostFacts @('cargo') @() @() 'a' 'b' }
    Refuses { Assert-CleanHostFacts @() @('Visual C++ Redistributable') @() 'a' 'b' }
    Refuses { Assert-CleanHostFacts @() @() @('Windows Kits') 'a' 'b' }
}
Check 'only exact clean timestamped publisher source admits' {
    Assert-ProductionManifest (Manifest) ('a' * 40) 'Fixture publisher'
    $m = Manifest; $m.source.dirty = $true; Refuses { Assert-ProductionManifest $m ('a' * 40) 'Fixture publisher' }
    $m = Manifest; $m.source.dirty = 'false'; Refuses { Assert-ProductionManifest $m ('a' * 40) 'Fixture publisher' }
    Refuses { Assert-ProductionManifest (Manifest) ('b' * 40) 'Fixture publisher' }
    Refuses { Assert-ProductionManifest (Manifest) ('a' * 40) 'Other publisher' }
    $m = Manifest; $m.signing.policy = 'development-pinned'; Refuses { Assert-ProductionManifest $m ('a' * 40) 'Fixture publisher' }
    $m = Manifest; $m.signing.timestamped = $false; Refuses { Assert-ProductionManifest $m ('a' * 40) 'Fixture publisher' }
    $m = Manifest; $m.signing.timestamped = 'true'; Refuses { Assert-ProductionManifest $m ('a' * 40) 'Fixture publisher' }
}
Check 'invalid, self-issued and untimestamped signature facts refuse' {
    Assert-ProductionSignature (Signature)
    $s = Signature; $s.Status = 'NotTrusted'; Refuses { Assert-ProductionSignature $s }
    $s = Signature; $s.SignerCertificate.Issuer = $s.SignerCertificate.Subject; Refuses { Assert-ProductionSignature $s }
    $s = Signature; $s.TimeStamperCertificate = $null; Refuses { Assert-ProductionSignature $s }
}
Check 'path escapes and ambiguous native spellings refuse' {
    foreach ($path in @('../escape', 'x/../escape', 'x\\escape', '/absolute', 'C:/absolute', 'x/./escape', 'x//escape', 'x./escape')) {
        Refuses { Get-SafeRelativePath $path }
    }
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixture = Join-Path $tempRoot ('arktrace-acceptance-contract-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $fixture -ErrorAction Stop)
function New-TestArchive([string]$Name, [object[]]$Extra = @(), [string]$Content = 'fixture', [int]$Attributes = 0) {
    $payload = [Text.Encoding]::UTF8.GetBytes('fixture')
    $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($payload)).ToLowerInvariant()
    $m = Manifest
    $m | Add-Member -MemberType NoteProperty -Name integrity -Value ([pscustomobject]@{
        files = @([pscustomobject]@{ path = 'payload.txt'; byteCount = $payload.Length; sha256 = $sha })
    })
    $manifestBytes = [Text.Encoding]::UTF8.GetBytes(($m | ConvertTo-Json -Depth 6))
    $path = Join-Path $fixture ($Name + '.zip')
    $file = [IO.File]::Open($path, 'CreateNew', 'ReadWrite', 'None')
    $zip = [IO.Compression.ZipArchive]::new($file, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entries = @([pscustomobject]@{ name = 'ArkTraceCLI-test/distribution-manifest.json'; bytes = $manifestBytes; attributes = 0 },
            [pscustomobject]@{ name = 'ArkTraceCLI-test/payload.txt'; bytes = [Text.Encoding]::UTF8.GetBytes($Content); attributes = $Attributes }) + $Extra
        foreach ($entry in $entries) {
            $member = $zip.CreateEntry($entry.name)
            $member.ExternalAttributes = $entry.attributes
            $stream = $member.Open()
            try { $stream.Write($entry.bytes, 0, $entry.bytes.Length) } finally { $stream.Dispose() }
        }
    }
    finally { $zip.Dispose(); $file.Dispose() }
    return [pscustomobject]@{ path = $path; archiveSha = (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
        manifestSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($manifestBytes)).ToLowerInvariant() }
}
function Expand-Fixture($Archive, [string]$Name) {
    return (Install-ExactArchive $Archive.path (Join-Path $fixture $Name) $Archive.archiveSha $Archive.manifestSha ('a' * 40) 'Fixture publisher')
}
try {
    $good = New-TestArchive 'good'
    Check 'closed hash-pinned fixture archive extracts without executing its bytes' {
        $result = Expand-Fixture $good 'good-install'
        if ([IO.File]::ReadAllText((Join-Path $result.root 'payload.txt')) -cne 'fixture') { throw 'Fixture extraction drift.' }
    }
    Check 'move is confined to this new work directory and cannot overwrite' {
        Assert-OwnedMove (Join-Path $fixture 'good-install') (Join-Path $fixture 'new-move') $fixture
        Refuses { Assert-OwnedMove (Join-Path $fixture 'good-install') (Join-Path $tempRoot 'outside-move') $fixture }
        Refuses { Assert-OwnedMove (Join-Path $fixture 'good-install') (Join-Path $fixture 'good-install') $fixture }
    }
    Check 'wrong build archive or manifest identity refuses' {
        Refuses { Install-ExactArchive $good.path (Join-Path $fixture 'bad-archive') ('0' * 64) $good.manifestSha ('a' * 40) 'Fixture publisher' }
        Refuses { Install-ExactArchive $good.path (Join-Path $fixture 'bad-manifest') $good.archiveSha ('0' * 64) ('a' * 40) 'Fixture publisher' }
    }
    Check 'undeclared, colliding and escaping archive entries refuse' {
        $extra = New-TestArchive 'extra' @([pscustomobject]@{ name = 'ArkTraceCLI-test/extra'; bytes = [byte[]]@(1); attributes = 0 })
        Refuses { Expand-Fixture $extra 'extra-install' }
        $collision = New-TestArchive 'collision' @([pscustomobject]@{ name = 'ArkTraceCLI-test/PAYLOAD.txt'; bytes = [byte[]]@(1); attributes = 0 })
        Refuses { Expand-Fixture $collision 'collision-install' }
        $escape = New-TestArchive 'escape' @([pscustomobject]@{ name = '../escape'; bytes = [byte[]]@(1); attributes = 0 })
        Refuses { Expand-Fixture $escape 'escape-install' }
    }
    Check 'modified payload and symlink attributes refuse' {
        $modified = New-TestArchive 'modified' @() 'drifted'
        Refuses { Expand-Fixture $modified 'modified-install' }
        $link = New-TestArchive 'link' @() 'fixture' -1577123840
        Refuses { Expand-Fixture $link 'link-install' }
    }
}
finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ([IO.Path]::GetDirectoryName($resolved) -cne $tempRoot -or
        [IO.Path]::GetFileName($resolved) -cnotmatch '^arktrace-acceptance-contract-[0-9a-f]{32}$' -or
        (Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Refusing fixture cleanup outside its verified temporary directory.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output "PASS $script:passed production acceptance guard regressions (synthetic; no production pass claim)."
