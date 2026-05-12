param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$ZipPath = "",

    [string]$NotesPath = "",
    [string]$Repo = "",
    [string]$AssetName = "",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Resolve-FullPath {
    param([string]$Path)

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    return $resolved.Path
}

function Invoke-Checked {
    param(
        [string]$Description,
        [string]$Command,
        [int]$Retries = 1
    )

    Write-Host ""
    Write-Host "==> $Description"
    Write-Host $Command

    if ($DryRun) {
        return
    }

    for ($attempt = 1; $attempt -le $Retries; $attempt += 1) {
        Invoke-Expression $Command
        if ($LASTEXITCODE -eq 0) {
            return
        }

        if ($attempt -lt $Retries) {
            Write-Host "Command failed. Retrying in 5 seconds ($attempt/$Retries)..."
            Start-Sleep -Seconds 5
        }
    }

    throw "Command failed after $Retries attempt(s): $Command"
}

function Invoke-NetworkChecked {
    param(
        [string]$Description,
        [string]$Command
    )

    Invoke-Checked -Description $Description -Command $Command -Retries 3
}

function Test-NativeSuccess {
    param([scriptblock]$Command)

    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $script:ErrorActionPreference = "Continue"
        & $Command *> $null
        return ($LASTEXITCODE -eq 0)
    } finally {
        $script:ErrorActionPreference = $oldErrorActionPreference
    }
}

function Get-ReleaseNotes {
    param(
        [string]$Path,
        [string]$DisplayVersion
    )

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $escaped = [regex]::Escape($DisplayVersion)
    $pattern = "(?ms)^##\s*$escaped\s*\r?\n(?<body>.*?)(?=^##\s+|\z)"
    $match = [regex]::Match($content, $pattern)

    if (-not $match.Success) {
        throw "Cannot find release notes section: ## $DisplayVersion"
    }

    $body = $match.Groups["body"].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($body)) {
        throw "Release notes section is empty: ## $DisplayVersion"
    }

    return "## $DisplayVersion`r`n`r`n$body`r`n"
}

function Get-RepoFromOrigin {
    $remote = git remote get-url origin
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remote)) {
        throw "Cannot read git remote origin. Pass -Repo owner/name."
    }

    if ($remote -match "github\.com[:/](?<owner>[^/]+)/(?<name>[^/.]+)(\.git)?$") {
        return "$($Matches.owner)/$($Matches.name)"
    }

    throw "Cannot parse GitHub repo from origin: $remote. Pass -Repo owner/name."
}

function New-ReleaseZip {
    param(
        [string]$RepoRoot,
        [string]$Destination
    )

    $stagingRoot = Join-Path $env:TEMP ("claude-typora-package-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $stagingRoot | Out-Null

    try {
        Get-ChildItem -LiteralPath $RepoRoot -Force |
            Where-Object {
                $_.Name -ne ".git" -and
                $_.Name -ne "release.ps1" -and
                $_.Name -ne "release.bat"
            } |
            ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination $stagingRoot -Recurse -Force
            }

        if (Test-Path -LiteralPath $Destination) {
            Remove-Item -LiteralPath $Destination -Force
        }

        Compress-Archive -Path (Join-Path $stagingRoot "*") -DestinationPath $Destination -Force
    } finally {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$repoRoot = git rev-parse --show-toplevel
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoRoot)) {
    throw "Run this script inside the git repository."
}

Set-Location $repoRoot

if ([string]::IsNullOrWhiteSpace($NotesPath)) {
    $defaultNotesName = (-join ([char[]](0x66F4, 0x65B0, 0x5185, 0x5BB9))) + ".md"
    $NotesPath = Join-Path $repoRoot $defaultNotesName
}

$versionNumber = $Version.Trim()
if ($versionNumber.StartsWith("v", [System.StringComparison]::OrdinalIgnoreCase)) {
    $versionNumber = $versionNumber.Substring(1)
}

if ([string]::IsNullOrWhiteSpace($versionNumber)) {
    throw "Version cannot be empty."
}

$tagName = "v$versionNumber"
$displayVersion = "V$versionNumber"

$notesFullPath = Resolve-FullPath $NotesPath

if ([string]::IsNullOrWhiteSpace($Repo)) {
    $Repo = Get-RepoFromOrigin
}

if ([string]::IsNullOrWhiteSpace($AssetName)) {
    $AssetName = "claude-theme-$versionNumber.zip"
}

if (-not $AssetName.EndsWith(".zip", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "AssetName must end with .zip"
}

$assetCopy = Join-Path $env:TEMP $AssetName

if ([string]::IsNullOrWhiteSpace($ZipPath)) {
    $zipFullPath = $assetCopy
} else {
    $zipFullPath = Resolve-FullPath $ZipPath
}

$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh) {
    $fallback = "C:\Program Files\GitHub CLI\gh.exe"
    if (Test-Path -LiteralPath $fallback) {
        $env:Path = "$(Split-Path -Parent $fallback);$env:Path"
    } else {
        throw "GitHub CLI is not installed. Install gh first."
    }
}

Write-Host "Repository: $Repo"
Write-Host "Tag:        $tagName"
Write-Host "Title:      $displayVersion"
Write-Host "Asset:      $AssetName"
Write-Host "Zip:        $(if ([string]::IsNullOrWhiteSpace($ZipPath)) { 'auto-generated from repository files' } else { $zipFullPath })"
Write-Host "Notes:      $notesFullPath"

Invoke-NetworkChecked "Fetch latest remote state" "git fetch origin main --tags"

$releaseExists = Test-NativeSuccess { gh release view $tagName --repo $Repo }

if ($releaseExists) {
    throw "Release already exists: $tagName"
}

$remoteTagExists = Test-NativeSuccess { git ls-remote --exit-code --tags origin "refs/tags/$tagName" }

if ($remoteTagExists) {
    throw "Remote tag already exists: $tagName"
}

$notesOutput = Join-Path $env:TEMP "claude-typora-$tagName-release-notes.md"
Get-ReleaseNotes -Path $notesFullPath -DisplayVersion $displayVersion | Set-Content -LiteralPath $notesOutput -Encoding UTF8

if (-not $DryRun) {
    if ([string]::IsNullOrWhiteSpace($ZipPath)) {
        New-ReleaseZip -RepoRoot $repoRoot -Destination $assetCopy
    } else {
        Copy-Item -LiteralPath $zipFullPath -Destination $assetCopy -Force
    }
}

Invoke-Checked "Stage repository changes" "git add -A"

$hasStagedChanges = $true
if (-not $DryRun) {
    git diff --cached --quiet
    $hasStagedChanges = ($LASTEXITCODE -ne 0)
}

if ($DryRun -or $hasStagedChanges) {
    Invoke-Checked "Commit release changes" "git commit -m 'Release $displayVersion'"
} else {
    Write-Host ""
    Write-Host "==> No file changes to commit; using current HEAD."
}

Invoke-Checked "Create local tag" "git tag $tagName"
Invoke-NetworkChecked "Push main" "git push origin main"
Invoke-NetworkChecked "Push tag" "git push origin $tagName"
Invoke-NetworkChecked "Create GitHub release" "gh release create $tagName '$assetCopy' --repo $Repo --title '$displayVersion' --notes-file '$notesOutput'"

Write-Host ""
Write-Host "Done: https://github.com/$Repo/releases/tag/$tagName"
