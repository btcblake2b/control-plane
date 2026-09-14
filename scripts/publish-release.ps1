<#
.SYNOPSIS
  Pubblica il repo control-plane sul repo pubblico btcblake2b/control-plane.

.DESCRIPTION
  Il repo di sviluppo resta privato con tutta la sua storia. Questo script crea
  nel repo pubblico UN SINGOLO commit per versione, contenente l'albero ESATTO
  del tag (solo file committati). Include lo snapshot di release del bridge
  (cartella bridge/), così installer + bridge sono ricostruibili da un unico
  repo pubblico.

.EXAMPLE
  .\scripts\publish-release.ps1 -Version 0.1.0
  .\scripts\publish-release.ps1 -Version 0.1.0 -CreateRelease

.NOTES
  Prerequisiti: git; tag v<Version> (creato qui se assente); gh CLI autenticato
  (per creare il repo pubblico se assente; con -CreateRelease anche per la
  release, richiedendo dist/ popolato da scripts/package-installer.sh e
  scripts/build-bridge-release.sh).
#>
param(
  [Parameter(Mandatory = $true)]
  [string]$Version,   # es. 0.1.0 (senza 'v')

  [string]$PublicRepo = 'https://github.com/btcblake2b/control-plane.git',
  [string]$PublicSlug = 'btcblake2b/control-plane',
  [string]$PublicName = 'btcblake2b',
  [string]$PublicEmail = 'progress@btcblake2b.org',

  [switch]$CreateRelease
)

$ErrorActionPreference = 'Stop'
$tag = "v$Version"
$root = Split-Path -Parent $PSScriptRoot

Write-Host "== Pubblicazione $tag -> $PublicRepo ==" -ForegroundColor Cyan

# ── 0) Il tag deve esistere nel repo di sviluppo ──────────────────────────
if (-not (git -C $root tag -l $tag)) {
  Write-Host "Tag $tag non trovato nel repo di sviluppo: lo creo su HEAD." -ForegroundColor Yellow
  git -C $root tag -a $tag -m "Release $tag"
}

# ── 0b) Il repo pubblico deve esistere (lo crea gh alla prima volta) ──────
gh repo view $PublicSlug *> $null
if ($LASTEXITCODE -ne 0) {
  Write-Host "Repo pubblico assente: lo creo con gh..." -ForegroundColor Yellow
  gh repo create $PublicSlug --public `
    --description 'Self-hosted support infrastructure for bitcoin-blake2b Lightning nodes: provisioning registry + assisted node installer (CLN fork blake2b + NWC/NCC bridge).' | Out-Null
}

# ── 1) Clone del repo pubblico in temp ────────────────────────────────────
$tmp = Join-Path $env:TEMP "btc-blake2b-cp-pub-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
git clone $PublicRepo $tmp
if ($LASTEXITCODE -ne 0) { throw "Clone fallito di $PublicRepo" }
git -C $tmp config user.name $PublicName
git -C $tmp config user.email $PublicEmail

# ── 2) Sostituisci il contenuto con l'albero del tag ──────────────────────
Push-Location $tmp
try {
  $trackedFiles = @(git ls-files)
  if ($trackedFiles.Count -gt 0) {
    git rm -rq --cached . 2>$null
  }
  Get-ChildItem -Force | Where-Object { $_.Name -ne '.git' } | Remove-Item -Recurse -Force

  # Estrae SOLO i file committati al tag (mai segreti/artefatti: dist/ è ignorata)
  $zip = Join-Path $tmp 'snapshot.zip'
  git -C $root archive --format=zip -o $zip $tag
  Expand-Archive -Path $zip -DestinationPath $tmp -Force
  Remove-Item $zip -Force

  # ── 3) Un singolo commit "Release" + tag + push ──────────────────────────
  git add -A
  git -c user.name="$PublicName" -c user.email="$PublicEmail" commit -m "Release $tag"
  git tag $tag
  git push origin HEAD:main --tags
  if ($LASTEXITCODE -ne 0) { throw "Push fallito (verifica credenziali account btcblake2b)" }
}
finally {
  Pop-Location
}

Write-Host ""
Write-Host "OK: $tag pubblicato su $PublicRepo (un singolo commit)." -ForegroundColor Green

# ── 4) (opzionale) GitHub Release con gli asset ───────────────────────────
if ($CreateRelease) {
  $assets = @(
    (Join-Path $root "dist/bridge-exe-linux-amd64"),
    (Join-Path $root "dist/tlw-node-installer-$Version.tar.gz"),
    (Join-Path $root "dist/SHA256SUMS")
  )
  foreach ($a in $assets) {
    if (-not (Test-Path $a)) { throw "Asset mancante: $a (esegui prima build-bridge-release.sh e package-installer.sh)" }
  }
  Write-Host "== Creo la GitHub Release $tag con asset ==" -ForegroundColor Cyan
  gh release create $tag --repo $PublicSlug --title "v$Version" `
    --notes "Node installer + bridge (linux-amd64). Verifica i checksum in SHA256SUMS. Guida: docs/INSTALLER.md." `
    @assets
  if ($LASTEXITCODE -ne 0) { throw "Creazione release fallita" }
  Write-Host "OK: release $tag creata con 3 asset." -ForegroundColor Green
}
else {
  Write-Host "Prossimi passi (release con asset):" -ForegroundColor Cyan
  Write-Host "  1. bash scripts/package-installer.sh          (produce dist/tlw-node-installer-$Version.tar.gz)"
  Write-Host "  2. dist/: crea SHA256SUMS con sha256sum bridge-exe-linux-amd64 tlw-node-installer-$Version.tar.gz"
  Write-Host "  3. .\scripts\publish-release.ps1 -Version $Version -CreateRelease   (crea la release)"
}
