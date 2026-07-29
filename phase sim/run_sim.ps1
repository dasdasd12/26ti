$ErrorActionPreference = "Stop"

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
python "$scriptDirectory\direct_calibration_sim.py" @args

if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
