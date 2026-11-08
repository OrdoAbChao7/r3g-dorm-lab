Remove-Item Env:MSYSTEM -ErrorAction SilentlyContinue
Set-Location $PSScriptRoot
pio run -t clean
cmd /c "pio run > build_psram.log 2>&1"
$rc = $LASTEXITCODE
"PIO_EXIT=$rc" | Out-File -FilePath build_psram.log -Append -Encoding ascii
exit $rc
