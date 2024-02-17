param ([string]$path, [string]$client, [bool]$noInterface = $false)

& "$PSScriptRoot/RunCloudCommand.ps1" -command "download" -path $path -client $client -noInterface $noInterface
