$ErrorActionPreference = "Stop"

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
python "$scriptDirectory\frequency_offset_sim.py" @args

if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
