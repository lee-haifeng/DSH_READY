# DSH Ready build helper.
#
# The HarmonyOS toolchain needs a few environment variables before hvigor can run, and
# this workspace keeps its build caches inside .buildhome so a build never writes into
# the user profile. Run:  pwsh -NoProfile -File scripts/build.ps1
#
# Parameters:
#   -Task    hvigor task, default assembleHap
#   -Clean   remove the hvigor project cache first

param(
  [string]$Task = 'assembleHap',
  [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$home2 = Join-Path $root '.buildhome'
$deveco = 'E:\DevEco Studio'

if (-not (Test-Path $deveco)) {
  throw "DevEco Studio not found at $deveco"
}

$env:DEVECO_SDK_HOME = Join-Path $deveco 'sdk'
$env:JAVA_HOME = Join-Path $deveco 'jbr'
$env:PATH = "$(Join-Path $deveco 'tools\node');$(Join-Path $deveco 'jbr\bin');$env:PATH"
$env:USERPROFILE = $home2
$env:HOME = $home2
$env:HOMEDRIVE = (Split-Path -Qualifier $home2)
$env:HOMEPATH = $home2.Substring(2)
$env:npm_config_cache = Join-Path $home2 'npm-cache'
$env:APPDATA = Join-Path $home2 'AppData\Roaming'
$env:LOCALAPPDATA = Join-Path $home2 'AppData\Local'

foreach ($dir in @($home2, $env:npm_config_cache, $env:APPDATA, $env:LOCALAPPDATA)) {
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
}

if ($Clean) {
  $cache = Join-Path $home2 '.hvigor\project_caches'
  if (Test-Path $cache) { Remove-Item $cache -Recurse -Force }
  $out = Join-Path $root '.hvigor'
  if (Test-Path $out) { Remove-Item $out -Recurse -Force }
}

Push-Location $root
try {
  # hvigor writes progress to stderr; with ErrorActionPreference=Stop PowerShell would
  # turn that into a terminating error, so relax it for the native call.
  $ErrorActionPreference = 'Continue'
  & (Join-Path $deveco 'tools\hvigor\bin\hvigorw.bat') --mode module -p 'product=default' -p 'module=entry@default' $Task --no-daemon
  $global:DSHBuildExitCode = $LASTEXITCODE
} finally {
  Pop-Location
}

Write-Host "DSH_BUILD_EXIT=$global:DSHBuildExitCode"
