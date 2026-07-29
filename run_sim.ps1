param(
    [string]$Testbench = "sim/tb_lissajous_top.sv",
    [string]$Output = "icarus/tb_lissajous_top.vvp",
    [string]$Waveform = "sim/tb_lissajous_top.vcd",
    [switch]$OpenWave
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path "icarus")) {
    New-Item -ItemType Directory -Path "icarus" | Out-Null
}

$sourceFiles = Get-ChildItem -Path "rtl" -Recurse -Include "*.v","*.sv" |
    Select-Object -ExpandProperty FullName
$testbenchPath = (Resolve-Path $Testbench).Path
$simulationSupportFiles =
    Get-ChildItem -Path "sim" -Recurse -Include "*.v","*.sv" |
    Where-Object { $_.FullName -ne $testbenchPath } |
    Select-Object -ExpandProperty FullName

Write-Host "Compiling SystemVerilog..."
& iverilog -g2012 -Wall -s tb_lissajous_top -o $Output `
    $Testbench $sourceFiles $simulationSupportFiles
if ($LASTEXITCODE -ne 0) {
    throw "iverilog failed with exit code $LASTEXITCODE"
}

Write-Host "Running simulation..."
& vvp $Output
if ($LASTEXITCODE -ne 0) {
    throw "vvp failed with exit code $LASTEXITCODE"
}

if (Test-Path $Waveform) {
    $wave = Get-Item $Waveform
    Write-Host "Waveform: $($wave.FullName) ($($wave.Length) bytes)"
    if ($OpenWave) {
        try {
            Start-Process -FilePath "gtkwave" -ArgumentList $wave.FullName
        } catch {
            Write-Warning "GTKWave could not be started; open the VCD manually."
        }
    }
} else {
    Write-Warning "Waveform was not generated: $Waveform"
}
