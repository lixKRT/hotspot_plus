param(
    [string]$AndroidJar = "$env:ANDROID_HOME\platforms\android-36\android.jar",
    [string]$D8 = "$env:ANDROID_HOME\build-tools\36.0.0\d8.bat",
    [string]$Output = "callback-probe.jar"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $PSScriptRoot "probe-src\com\hsp\probe\CallbackProbe.java"
$build = Join-Path $env:TEMP ("hsp-callback-probe-" + [guid]::NewGuid().ToString("N"))

if (-not (Test-Path $AndroidJar)) { throw "android.jar not found: $AndroidJar" }
if (-not (Test-Path $D8)) { throw "d8 not found: $D8" }

try {
    New-Item -ItemType Directory -Force $build | Out-Null
    & javac -nowarn -Xlint:-options -source 8 -target 8 `
        -bootclasspath $AndroidJar -d $build $source
    if ($LASTEXITCODE -ne 0) { throw "javac failed" }

    $classes = Get-ChildItem (Join-Path $build "com\hsp\probe\*.class") |
        ForEach-Object FullName
    & $D8 --release --min-api 30 --lib $AndroidJar --output $build $classes
    if ($LASTEXITCODE -ne 0) { throw "d8 failed" }

    $jar = Join-Path $build "callback-probe.jar"
    Push-Location $build
    try {
        & jar cf $jar "classes.dex"
        if ($LASTEXITCODE -ne 0) { throw "jar failed" }
    } finally {
        Pop-Location
    }
    $destination = Join-Path $root $Output
    $parent = Split-Path -Parent $destination
    if ($parent) { New-Item -ItemType Directory -Force $parent | Out-Null }
    Copy-Item -Force $jar $destination
    Write-Output $destination
} finally {
    Remove-Item -Recurse -Force $build -ErrorAction SilentlyContinue
}
