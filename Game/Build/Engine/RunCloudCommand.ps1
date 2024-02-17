param (
    [Parameter(mandatory)] [string]$command,
    [string]$client,
    [string]$path,
    [bool]$noInterface = $false
)

try {
	$config = ([xml](Get-Content "$PSScriptRoot/Config.xml")).root

	if (-Not $client) {
		$client = $config.defaultClient
	}

	$useInterface = -Not($noInterface)

	if ($useInterface) {
		Add-Type -AssemblyName System.Windows.Forms
		Add-Type -AssemblyName System.Drawing

		$form = New-Object System.Windows.Forms.Form
		$form.Size = New-Object System.Drawing.Size(700, 600)
		$form.FormBorderStyle = 'FixedSingle'
		$form.StartPosition = 'CenterScreen'
		$form.TopMost = $false
		$form.ControlBox = $false
		$form.Text = 'Binary Engine Syncing'

		$textBox = New-Object System.Windows.Forms.TextBox
		$textBox.Location = New-Object System.Drawing.Point(5, 5)
		$textBox.Size = New-Object System.Drawing.Size(675, 550)
		$textBox.Multiline = $true
		$textbox.WordWrap = $false
		$textbox.ReadOnly = $true
		$textBox.ScrollBars = 'Both'
		$textBox.Name = 'Message'
		
		$sharedData = [hashtable]::Synchronized(@{
			textBox = $textBox
			form = $form
		})

		$form.Controls.Add($sharedData.textBox)

		# Set up a separate thread for the form so that it'll stay interactive while we're running blocking commands
		$ps = [PowerShell]::Create()
		[void]$ps.AddScript({
			[System.Windows.Forms.Application]::Run($sharedData.form)
		})
		$ps.Runspace.SessionStateProxy.SetVariable("sharedData", $sharedData)
	}

	$ThisWindow = $false
	function setWindowVisible($visible) {
		if (-Not $ThisWindow) {
			$sig = '[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);'
			Add-Type -MemberDefinition $sig -Name Functions -Namespace Win32
			$ThisWindow = [System.Diagnostics.Process]::GetCurrentProcess().MainWindowHandle
		}

		[void][Win32.Functions]::ShowWindow($ThisWindow, $(if ($visible) { 5 } else { 0 }))
	}

	function SetMessage($NewMessage) {
		if (-Not $NewMessage) {
			Return
		}

		Write-Output $NewMessage

		if ($useInterface) {
			$sharedData.textBox.AppendText("$NewMessage`r`n")
		}
	}

	function OutMessage {
		[CmdletBinding()]
		Param(
		  [Parameter(ValueFromPipeline=$True)]
		  [String[]] $Log
		)

		process
		{
			SetMessage($Log)
		}
	}

	# Updates PATH after an installation so that we can call the new program without restarting
	function updatePath {
		$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User") 
	}

	function ShowModal {
		if ($useInterface) {
			# Hide this window
			setWindowVisible($false)

			# Show status window (only done here because AWS CLI installation has its own window)
			[void]$ps.BeginInvoke()

			# Wait until the text box is fully created, as without this we've run into
			# some random freezes when setting text / disposing form
			while (-Not $sharedData.textBox.Created) {
				Start-Sleep -Milliseconds 1
			}
		}
	}

	function isModalOpen {
		return $useInterface -and $ps.InvocationStateInfo.State -eq "Running"
	}

	function closeModal {
		[System.Windows.Forms.Application]::Exit()
		$ps.Dispose()
	}

	switch ($client)
	{
		"aws" {
			# If AWS CLI is not installed yet, install it
			if (-Not(Get-Command "aws" -errorAction SilentlyContinue)) {
				& msiexec.exe /i https://awscli.amazonaws.com/AWSCLIV2.msi /passive
				updatePath
			}

			$Env:AWS_ACCESS_KEY_ID=$config.key
			$Env:AWS_SECRET_ACCESS_KEY=$config.secret
			$Env:AWS_ENDPOINT_URL=$config.endpointUrl
			$Env:AWS_REGION=$config.region
			Break
		}

		"rclone" {
			if (-Not(Get-Command "rclone" -errorAction SilentlyContinue)) {
				Start-Process winget -ArgumentList "install Rclone.Rclone --accept-source-agreements --accept-package-agreements" -Wait
				updatePath
			}

			$Env:RCLONE_CONFIG_REMOTE_TYPE='s3'
			$Env:RCLONE_CONFIG_REMOTE_PROVIDER=$config.rcloneProvider
			$Env:RCLONE_CONFIG_REMOTE_ACCESS_KEY_ID=$config.key
			$Env:RCLONE_CONFIG_REMOTE_SECRET_ACCESS_KEY=$config.secret
			$Env:RCLONE_CONFIG_REMOTE_ENDPOINT=$config.endpointUrl
			$Env:RCLONE_CONFIG_REMOTE_REGION=$config.region
			$Env:RCLONE_CONFIG_REMOTE_ACL=$config.rcloneAcl
			Break
		}

		Default {
			Write-Output "Client not recognized: $client."
		}
	}

	# If no custom path is specified, let's use the great-grandparent of the script location
	if (-Not($path)) {
		# ThisFolder/../../..
		$path = $PSScriptRoot | Split-Path | Split-Path | Split-Path
	}
	else {
		$path = $path.TrimEnd('\').TrimEnd('/')
	}

	$enginePath = Join-Path -Path $path -ChildPath 'Engine'

	# Create the path if it does not exist yet
	mkdir -Force $enginePath | Out-Null
	Write-Output "Initializing for engine path $enginePath..."

	$bucketPath = "s3://$($config.bucketName)/"
	$localVersionFilePath = "$path\$($config.versionFile)"

	switch ($command) {
		"upload" {
			ShowModal

			$bucketVersionFilePath = "$($config.versionBucketName)/$($config.versionFile)"
			switch ($client) {
				"aws" {
					# We check for the size, because otherwise we'll keep re-submitting unchanged binaries that
					# have their modified date changed by MSVC. Optimally, we'd check for checksum,
					# but that's not available yet nicely: https://github.com/aws/aws-cli/issues/6750
					& aws s3 sync $enginePath $bucketPath --size-only | OutMessage
					& aws s3 cp $localVersionFilePath "s3://$bucketVersionFilePath" | OutMessage
					Break
				}

				"rclone" {
					& rclone sync $enginePath remote:$($config.bucketName) --checksum --fast-list --progress --checkers 16 --transfers 16 --config="" | OutMessage
					& rclone copyto $localVersionFilePath remote:$bucketVersionFilePath --s3-no-check-bucket --config="" | OutMessage
				}
			}

			Break
		}

		"download" {
			$version = [int](Invoke-webrequest -URI "$($config.versionFileUrl)/$($config.versionFile)").Content
			$localVersion = [int](Get-Content -Path $localVersionFilePath -ErrorAction 'SilentlyContinue')

			# Server version is <= current version
			if ($version -le $localVersion) {
				Write-Output "Version is already the latest ($localVersion)"
				Break
			}

			ShowModal

			switch ($client) {
				"aws" {
					& aws s3 sync $bucketPath $enginePath | OutMessage
					Break
				}

				"rclone" {
					& rclone sync remote:$($config.bucketName) $enginePath --update --use-server-modtime --fast-list --progress --checkers 32 --transfers 32 --config="" | OutMessage
				}
			}

			# Register the engine
			Set-ItemProperty -Path "Registry::HKEY_CURRENT_USER\SOFTWARE\Epic Games\Unreal Engine\Builds" -Name $config.registryEngineName -Value "$path"

			# Write the version file at the end
			Set-Content -Path $localVersionFilePath -Value $version

			# Install prerequisites
			& $enginePath\Extras\Redist\en-us\UE4PrereqSetup_x64.exe /quiet | OutMessage

			Break
		}

		Default {
			Write-Output "Unrecognized command: $command."
		}
	}
}
catch {
	if (isModalOpen) {
		# Show the powershell window as it'll contain the error message
		setWindowVisible($true)
		closeModal
	}

	# Print error message
	$_

	pause
}
finally {
	if (isModalOpen) {
		closeModal
	}
}
