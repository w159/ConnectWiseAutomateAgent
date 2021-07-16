Function Get-CurrentLineNumber {
    [Alias('LINENUM')]
    param()
    $MyInvocation.ScriptLineNumber
}
function Initialize-CWAA {
    if (-not ($PSVersionTable)) {
        Write-Warning 'PS1 Detected. PowerShell Version 2.0 or higher is required.'
        return
    }
    if (-not ($PSVersionTable) -or $PSVersionTable.PSVersion.Major -lt 3 ) { Write-Verbose 'PS2 Detected. PowerShell Version 3.0 or higher may be required for full functionality.' }
    If ($env:PROCESSOR_ARCHITEW6432 -match '64' -and [IntPtr]::Size -ne 8) {
        Write-Warning '32-bit PowerShell session detected on 64-bit OS. Attempting to launch 64-Bit session to process commands.'
        $pshell="${env:WINDIR}\sysnative\windowspowershell\v1.0\powershell.exe"
        If (!(Test-Path -Path $pshell)) {
            Write-Warning 'SYSNATIVE PATH REDIRECTION IS NOT AVAILABLE. Attempting to access 64-bit PowerShell directly.'
            $pshell="${env:WINDIR}\System32\WindowsPowershell\v1.0\powershell.exe"
            $FSRedirection=$True
            Add-Type -Debug:$False -Name Wow64 -Namespace "Kernel32" -MemberDefinition @"
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool Wow64DisableWow64FsRedirection(ref IntPtr ptr);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool Wow64RevertWow64FsRedirection(ref IntPtr ptr);
"@
            [ref]$ptr = New-Object System.IntPtr
            $Result = [Kernel32.Wow64]::Wow64DisableWow64FsRedirection($ptr) # Now you can call 64-bit Powershell from system32
        }
        If ($myInvocation.Line) {
            &"$pshell" -NonInteractive -NoProfile $myInvocation.Line
        } Elseif ($myInvocation.InvocationName) {
            &"$pshell" -NonInteractive -NoProfile -File "$($myInvocation.InvocationName)" $args
        } Else {
            &"$pshell" -NonInteractive -NoProfile $myInvocation.MyCommand
        }
        $ExitResult=$LASTEXITCODE
        If ($FSRedirection -eq $True) {
            [ref]$defaultptr = New-Object System.IntPtr
            $Result = [Kernel32.Wow64]::Wow64RevertWow64FsRedirection($defaultptr)
        }
        Write-Warning 'Exiting 64-bit session. Module will only remain loaded in native 64-bit PowerShell environment.'
        Exit $ExitResult
    }
    #Ignore SSL errors
    Add-Type -Debug:$False @"
        using System.Net;
        using System.Security.Cryptography.X509Certificates;
        public class TrustAllCertsPolicy : ICertificatePolicy {
            public bool CheckValidationResult(
                ServicePoint srvPoint, X509Certificate certificate,
                WebRequest request, int certificateProblem) {
                return true;
            }
        }
"@
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    #Enable TLS, TLS1.1, TLS1.2, TLS1.3 in this session if they are available
    IF([Net.SecurityProtocolType]::Tls) {[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls}
    IF([Net.SecurityProtocolType]::Tls11) {[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls11}
    IF([Net.SecurityProtocolType]::Tls12) {[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12}
    IF([Net.SecurityProtocolType]::Tls13) {[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13}
    $Null=Initialize-CWAAModule
}
Function Initialize-CWAAKeys {
    [CmdletBinding()]
    Param()
    Process {
        $LTSI=Get-CWAAInfo -EA 0 -Verbose:$False -WhatIf:$False -Confirm:$False -Debug:$False
        If (($LTSI) -and ($LTSI|Get-Member|Where-Object {$_.Name -eq 'ServerPassword'})) {
            Write-Debug "Line $(LINENUM): Decoding Server Password."
            $Script:LTServiceKeys.ServerPasswordString=$(ConvertFrom-CWAASecurity -InputString "$($LTSI.ServerPassword)")
            If ($Null -ne $LTSI -and ($LTSI|Get-Member|Where-Object {$_.Name -eq 'Password'})) {
                Write-Debug "Line $(LINENUM): Decoding Agent Password."
                $Script:LTServiceKeys.PasswordString=$(ConvertFrom-CWAASecurity -InputString "$($LTSI.Password)" -Key "$($Script:LTServiceKeys.ServerPasswordString)")
            } Else {
                $Script:LTServiceKeys.PasswordString=''
            }
        } Else {
            $Script:LTServiceKeys.ServerPasswordString=''
            $Script:LTServiceKeys.PasswordString=''
        }
    }
    End {
    }
}
Function Initialize-CWAAModule {
    #Populate $Script:LTServiceKeys Object
    $Script:LTServiceKeys = New-Object -TypeName PSObject
    Add-Member -InputObject $Script:LTServiceKeys -MemberType NoteProperty -Name ServerPasswordString -Value ''
    Add-Member -InputObject $Script:LTServiceKeys -MemberType NoteProperty -Name PasswordString -Value ''
    #Populate $Script:LTProxy Object
    Try{
        $Script:LTProxy = New-Object -TypeName PSObject
        Add-Member -InputObject $Script:LTProxy -MemberType NoteProperty -Name ProxyServerURL -Value ''
        Add-Member -InputObject $Script:LTProxy -MemberType NoteProperty -Name ProxyUsername -Value ''
        Add-Member -InputObject $Script:LTProxy -MemberType NoteProperty -Name ProxyPassword -Value ''
        Add-Member -InputObject $Script:LTProxy -MemberType NoteProperty -Name Enabled -Value ''
        #Populate $Script:LTWebProxy Object
        $Script:LTWebProxy = New-Object System.Net.WebProxy
        #Initialize $Script:LTServiceNetWebClient Object
        $Script:LTServiceNetWebClient = New-Object System.Net.WebClient
        $Script:LTServiceNetWebClient.Proxy = $Script:LTWebProxy
    } Catch {
        Write-Error "ERROR: Line $(LINENUM): Failed Initializing internal Proxy Objects/Variables."
    }
    $Null = Get-CWAAProxy -ErrorAction Continue
}
Function ConvertFrom-CWAASecurity{
    [CmdletBinding()]
    [Alias('ConvertFrom-LTSecurity')]
    Param(
        [parameter(Mandatory = $true, ValueFromPipeline = $True, ValueFromPipelineByPropertyName = $True, Position = 1)]
        [string[]]$InputString,
        [parameter(Mandatory = $false, ValueFromPipeline = $false, ValueFromPipelineByPropertyName = $True)]
        [AllowNull()]
        [string[]]$Key,
        [parameter(Mandatory = $false, ValueFromPipeline = $false, ValueFromPipelineByPropertyName = $false)]
        [switch]$Force=$True
    )
    Begin {
        $DefaultKey='Thank you for using LabTech.'
        $_initializationVector = [byte[]](240, 3, 45, 29, 0, 76, 173, 59)
        $NoKeyPassed=$False
        $DecodedString=$Null
        $DecodeString=$Null
    }
    Process {
        If ($Null -eq $Key) {
            $NoKeyPassed=$True
            $Key=$DefaultKey
        }
        foreach ($testInput in $InputString) {
            $DecodeString=$Null
            foreach ($testKey in $Key) {
                If ($Null -eq $DecodeString) {
                    If ($Null -eq $testKey) {
                        $NoKeyPassed=$True
                        $testKey=$DefaultKey
                    }
                    Write-Debug "Line $(LINENUM): Attempting Decode for '$($testInput)' with Key '$($testKey)'"
                    Try {
                        $numarray=[System.Convert]::FromBase64String($testInput)
                        $ddd = new-object System.Security.Cryptography.TripleDESCryptoServiceProvider
                        $ddd.key=(new-Object Security.Cryptography.MD5CryptoServiceProvider).ComputeHash([Text.Encoding]::UTF8.GetBytes($testKey))
                        $ddd.IV=$_initializationVector
                        $dd=$ddd.CreateDecryptor()
                        $DecodeString=[System.Text.Encoding]::UTF8.GetString($dd.TransformFinalBlock($numarray,0,($numarray.Length)))
                        $DecodedString+=@($DecodeString)
                    } Catch {
                    }
                    Finally {
                        if ((Get-Variable -Name dd -Scope 0 -EA 0)) {try {$dd.Dispose()} catch {$dd.Clear()}}
                        if ((Get-Variable -Name ddd -Scope 0 -EA 0)) {try {$ddd.Dispose()} catch {$ddd.Clear()}}
                    }
                } Else {
                }
            }
            If ($Null -eq $DecodeString) {
                If ($Force) {
                    If (($NoKeyPassed)) {
                        $DecodeString=ConvertFrom-CWAASecurity -InputString "$($testInput)" -Key '' -Force:$False
                        If (-not ($Null -eq $DecodeString)) {
                            $DecodedString+=@($DecodeString)
                        }
                    } Else {
                        $DecodeString=ConvertFrom-CWAASecurity -InputString "$($testInput)"
                        if (-not ($Null -eq $DecodeString)) {
                            $DecodedString+=@($DecodeString)
                        }
                    }
                } Else {
                }
            }
        }
    }
    End {
        If ($Null -eq $DecodedString) {
            Write-Debug "Line $(LINENUM): Failed to Decode string: '$($InputString)'"
            return $Null
        } else {
            return $DecodedString
        }
    }
}
Function ConvertTo-CWAASecurity{
    [CmdletBinding()]
    [Alias('ConvertTo-LTSecurity')]
    Param(
        [parameter(Mandatory = $true, ValueFromPipeline = $false, ValueFromPipelineByPropertyName = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [string]$InputString,
        [parameter(Mandatory = $false, ValueFromPipeline = $false, ValueFromPipelineByPropertyName = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        $Key
    )
    Begin {
        $_initializationVector = [byte[]](240, 3, 45, 29, 0, 76, 173, 59)
        $DefaultKey='Thank you for using LabTech.'
        If ($Null -eq $Key) {
            $Key=$DefaultKey
        }
        try {
            $numarray=[System.Text.Encoding]::UTF8.GetBytes($InputString)
        } catch {
            try { $numarray=[System.Text.Encoding]::ASCII.GetBytes($InputString) } catch {}
        }
        Write-Debug "Line $(LINENUM): Attempting Encode for '$($testInput)' with Key '$($testKey)'"
        try {
            $ddd = new-object System.Security.Cryptography.TripleDESCryptoServiceProvider
            $ddd.key=(new-Object Security.Cryptography.MD5CryptoServiceProvider).ComputeHash([Text.Encoding]::UTF8.GetBytes($Key))
            $ddd.IV=$_initializationVector
            $dd=$ddd.CreateEncryptor()
            $str=[System.Convert]::ToBase64String($dd.TransformFinalBlock($numarray,0,($numarray.Length)))
        }
        catch {
            Write-Debug "Line $(LINENUM): Failed to Encode string: '$($InputString)'"
            $str=''
        }
        Finally
        {
            if ($dd) {try {$dd.Dispose()} catch {$dd.Clear()}}
            if ($ddd) {try {$ddd.Dispose()} catch {$ddd.Clear()}}
        }
        return $str
    }
}
Function Invoke-CWAACommand {
    [CmdletBinding(SupportsShouldProcess=$True)]
    [Alias('Invoke-LTServiceCommand')]
    Param(
        [Parameter(Mandatory=$True, Position=1, ValueFromPipeline=$True)]
        [ValidateSet("Update Schedule",
                        "Send Inventory",
                        "Send Drives",
                        "Send Processes",
                        "Send Spyware List",
                        "Send Apps",
                        "Send Events",
                        "Send Printers",
                        "Send Status",
                        "Send Screen",
                        "Send Services",
                        "Analyze Network",
                        "Write Last Contact Date",
                        "Kill VNC",
                        "Kill Trays",
                        "Send Patch Reboot",
                        "Run App Care Update",
                        "Start App Care Daytime Patching")][string[]]$Command
    )
    Begin {
        $Service = Get-Service 'LTService'
    }
    Process {
        If (-not ($Service)) {Write-Warning "WARNING: Line $(LINENUM): Service 'LTService' was not found. Cannot send service command"; return}
        If ($Service.Status -ne 'Running') {Write-Warning "WARNING: Line $(LINENUM): Service 'LTService' is not running. Cannot send service command"; return}
        Foreach ($Cmd in $Command) {
            $CommandID=$Null
            Try{
                switch($Cmd){
                    'Update Schedule' {$CommandID = 128}
                    'Send Inventory' {$CommandID = 129}
                    'Send Drives' {$CommandID = 130}
                    'Send Processes' {$CommandID = 131}
                    'Send Spyware List'{$CommandID = 132}
                    'Send Apps' {$CommandID = 133}
                    'Send Events' {$CommandID = 134}
                    'Send Printers' {$CommandID = 135}
                    'Send Status' {$CommandID = 136}
                    'Send Screen' {$CommandID = 137}
                    'Send Services' {$CommandID = 138}
                    'Analyze Network' {$CommandID = 139}
                    'Write Last Contact Date' {$CommandID = 140}
                    'Kill VNC' {$CommandID = 141}
                    'Kill Trays' {$CommandID = 142}
                    'Send Patch Reboot' {$CommandID = 143}
                    'Run App Care Update' {$CommandID = 144}
                    'Start App Care Daytime Patching' {$CommandID = 145}
                    default {"Invalid entry"}
                }
                If ($PSCmdlet.ShouldProcess("LTService", "Send Service Command '$($Cmd)' ($($CommandID))")) {
                    If ($Null -ne $CommandID) {
                        Write-Debug "Line $(LINENUM): Sending service command '$($Cmd)' ($($CommandID)) to 'LTService'"
                        Try {
                            $Null=& "$env:windir\system32\sc.exe" control LTService $($CommandID) 2>''
                            Write-Output "Sent Command '$($Cmd)' to 'LTService'"
                        }
                        Catch {
                            Write-Output "Error calling sc.exe. Failed to send command."
                        }
                    }
                }
            }
            Catch{
                Write-Warning ("WARNING: Line $(LINENUM)",$_.Exception)
            }
        }
    }
    End{}
}
Function Test-CWAAPort {
    [CmdletBinding()]
    [Alias('Test-LTPorts')]
    Param(
        [Parameter(ValueFromPipelineByPropertyName = $true, ValueFromPipeline=$True)]
        [string[]]$Server,
        [Parameter(ValueFromPipelineByPropertyName = $true)]
        [int]$TrayPort,
        [Parameter(ValueFromPipelineByPropertyName = $true)]
        [switch]$Quiet
    )
    Begin{
        $Mediator = 'mediator.labtechsoftware.com'
        Function Private:TestPort{
            Param(
                [parameter(Position=0)]
                [string]
                $ComputerName,
                [parameter(Mandatory=$False)]
                [System.Net.IPAddress]
                $IPAddress,
                [parameter(Mandatory=$True , Position=1)]
                [int]
                $Port
            )
            $RemoteServer = If ([string]::IsNullOrEmpty($ComputerName)) {$IPAddress} Else {$ComputerName};
            If ([string]::IsNullOrEmpty($RemoteServer)) {Write-Error "ERROR: Line $(LINENUM): No ComputerName or IPAddress was provided to test."; return}
            $test = New-Object System.Net.Sockets.TcpClient;
            Try
            {
                Write-Output "Connecting to $($RemoteServer):$Port (TCP)..";
                $test.Connect($RemoteServer, $Port);
                Write-Output "Connection successful";
            }
            Catch
            {
                Write-Output "ERROR: Connection failed";
                $Global:PortTestError = 1
            }
            Finally
            {
                $test.Close();
            }
        }
        Clear-Variable CleanSvr,svr,proc,processes,port,netstat,line -EA 0 -WhatIf:$False -Confirm:$False #Clearing Variables for use
        Write-Debug "Starting $($myInvocation.InvocationName) at line $(LINENUM)"
    }
    Process{
        If (-not ($Server) -and (-not ($TrayPort) -or -not ($Quiet))){
            Write-Verbose 'No Server Input - Checking for names.'
            $Server = Get-CWAAInfo -EA 0 -Verbose:$False -WhatIf:$False -Confirm:$False -Debug:$False|Select-Object -Expand 'Server' -EA 0
            If (-not ($Server)){
                Write-Verbose 'No Server found in installed Service Info. Checking for Service Backup.'
                $Server = Get-CWAAInfoBackup -EA 0 -Verbose:$False|Select-Object -Expand 'Server' -EA 0
            }
        }
        If (-not ($Quiet) -or (($TrayPort) -ge 1 -and ($TrayPort) -le 65530)){
            If (-not ($TrayPort) -or -not (($TrayPort) -ge 1 -and ($TrayPort) -le 65530)){
                #Learn LTTrayPort if available.
                $TrayPort = (Get-CWAAInfo -EA 0 -Verbose:$False -WhatIf:$False -Confirm:$False -Debug:$False|Select-Object -Expand TrayPort -EA 0)
            }
            If (-not ($TrayPort) -or $TrayPort -notmatch '^\d+$') {$TrayPort=42000}
            [array]$processes = @()
            #Get all processes that are using LTTrayPort (Default 42000)
            Try {$netstat=& "$env:windir\system32\netstat.exe" -a -o -n | Select-String -Pattern " .*[0-9\.]+:$($TrayPort).*[0-9\.]+:[0-9]+ .*?([0-9]+)" -EA 0}
            Catch {Write-Output "Error calling netstat.exe."; $netstat=$null}
            Foreach ($line In $netstat){
                $processes += ($line -split ' {4,}')[-1]
            }
            $processes = $processes | Where-Object {$_ -gt 0 -and $_ -match '^\d+$'}| Sort-Object | Get-Unique
            If (($processes)) {
                If (-not ($Quiet)){
                    Foreach ($proc In $processes) {
                        If ((Get-Process -ID $proc -EA 0|Select-Object -Expand ProcessName -EA 0) -eq 'LTSvc') {
                            Write-Output "TrayPort Port $TrayPort is being used by LTSvc."
                        } Else {
                            Write-Output "Error: TrayPort Port $TrayPort is being used by $(Get-Process -ID $proc|Select-Object -Expand ProcessName -EA 0)."
                        }
                    }
                } Else {return $False}
            } ElseIf (($Quiet) -eq $True){
                return $True
            } Else {
                Write-Output "TrayPort Port $TrayPort is available."
            }
        }
        foreach ($svr in $Server) {
            if ($Quiet){
                $CleanSvr = ($Svr -replace 'https?://',''|ForEach-Object {$_.Trim()})
                Test-Connection $CleanSvr -Quiet
                return
            }
            If ($Svr -match '^(https?://)?(([12]?[0-9]{1,2}\.){3}[12]?[0-9]{1,2}|[a-z0-9][a-z0-9_-]*(\.[a-z0-9][a-z0-9_-]*)*)$') {
                Try{
                    $CleanSvr = ($Svr -replace 'https?://',''|ForEach-Object {$_.Trim()})
                    Write-Output "Testing connectivity to required TCP ports:"
                    TestPort -ComputerName $CleanSvr -Port 70
                    TestPort -ComputerName $CleanSvr -Port 80
                    TestPort -ComputerName $CleanSvr -Port 443
                    TestPort -ComputerName $Mediator -Port 8002
                }
                Catch{
                    Write-Error "ERROR: Line $(LINENUM): There was an error testing the ports. $($Error[0])" -ErrorAction Stop
                }
            } Else {
                Write-Warning "WARNING: Line $(LINENUM): Server address $($Svr) is not a valid address or is not formatted correctly. Example: https://lt.domain.com"
            }
        }
    }
    End{
        If ($?){
            if (-not ($Quiet)){
                Write-Output "Test-CWAAPorts Finished"
            }
        }
        Else{$Error[0]}
        Write-Debug "Exiting $($myInvocation.InvocationName) at line $(LINENUM)"
    }
}
Function Hide-CWAAAddRemove{
    [CmdletBinding(SupportsShouldProcess=$True)]
    [Alias('Hide-LTAddRemove')]
    Param()
    Begin{
        Write-Debug "Starting $($myInvocation.InvocationName) at line $(LINENUM)"
        $RegRoots = ('HKLM:\SOFTWARE\Classes\Installer\Products\C4D064F3712D4B64086B5BDE05DBC75F',
        'HKLM:\SOFTWARE\Classes\Installer\Products\D1003A85576B76D45A1AF09A0FC87FAC')
        $PublisherRegRoots = ('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{58A3001D-B675-4D67-A5A1-0FA9F08CF7CA}',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{58A3001D-B675-4D67-A5A1-0FA9F08CF7CA}',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{3F460D4C-D217-46B4-80B6-B5ED50BD7CF5}',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{3F460D4C-D217-46B4-80B6-B5ED50BD7CF5}')
        $RegEntriesFound=0
        $RegEntriesChanged=0
    }
    Process{
        Try{
            Foreach($RegRoot in $RegRoots){
                If (Test-Path $RegRoot){
                    If (Get-ItemProperty $RegRoot -Name HiddenProductName -ErrorAction SilentlyContinue) {
                        If (!(Get-ItemProperty $RegRoot -Name ProductName -ErrorAction SilentlyContinue)) {
                            Write-Verbose "LabTech found with HiddenProductName value."
                            Try{
                                Rename-ItemProperty $RegRoot -Name HiddenProductName -NewName ProductName
                            }
                            Catch{
                                Write-Error "ERROR: Line $(LINENUM): There was an error renaming the registry value. $($Error[0])" -ErrorAction Stop
                            }
                        } Else {
                            Write-Verbose "LabTech found with unused HiddenProductName value."
                            Try{
                                Remove-ItemProperty $RegRoot -Name HiddenProductName -EA 0 -Confirm:$False -WhatIf:$False -Force
                            }
                            Catch{}
                        }
                    }
                }
            }
            Foreach($RegRoot in $PublisherRegRoots){
                If (Test-Path $RegRoot){
                    $RegKey=Get-Item $RegRoot -ErrorAction SilentlyContinue
                    If ($RegKey){
                        $RegEntriesFound++
                        If ($PSCmdlet.ShouldProcess("$($RegRoot)", "Set Registry Values to Hide $($RegKey.GetValue('DisplayName'))")){
                            $RegEntriesChanged++
                            @('SystemComponent') | ForEach-Object {
                                If (($RegKey.GetValue("$($_)")) -ne 1) {
                                    Write-Verbose "Setting $($RegRoot)\$($_)=1"
                                    Set-ItemProperty $RegRoot -Name "$($_)" -Value 1 -Type DWord -WhatIf:$False -Confirm:$False -Verbose:$False
                                }
                            }
                        }
                    }
                }
            }
        }
        Catch{
            Write-Error "ERROR: Line $(LINENUM): There was an error setting the registry values. $($Error[0])" -ErrorAction Stop
        }
    }
    End{
        If ($WhatIfPreference -ne $True) {
            If ($?){
                If ($RegEntriesFound -gt 0 -and $RegEntriesChanged -eq $RegEntriesFound) {
                    Write-Output "LabTech is hidden from Add/Remove Programs."
                } Else {
                    Write-Warning "WARNING: Line $(LINENUM): LabTech may not be hidden from Add/Remove Programs."
                }
            }
            Else {$Error[0]}
        }
        Write-Debug "Exiting $($myInvocation.InvocationName) at line $(LINENUM)"
    }
}
Function Rename-CWAAAddRemove{
    [CmdletBinding(SupportsShouldProcess=$True)]
    [Alias('Rename-LTAddRemove')]
    Param(
        [Parameter(Mandatory=$True)]
        $Name,
        [Parameter(Mandatory=$False)]
        [AllowNull()]
        [string]$PublisherName
    )
    Begin{
        $RegRoots = ('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{58A3001D-B675-4D67-A5A1-0FA9F08CF7CA}',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{58A3001D-B675-4D67-A5A1-0FA9F08CF7CA}',
        'HKLM:\SOFTWARE\Classes\Installer\Products\C4D064F3712D4B64086B5BDE05DBC75F',
        'HKLM:\SOFTWARE\Classes\Installer\Products\D1003A85576B76D45A1AF09A0FC87FAC')
        $PublisherRegRoots = ('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{58A3001D-B675-4D67-A5A1-0FA9F08CF7CA}',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{58A3001D-B675-4D67-A5A1-0FA9F08CF7CA}',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{3F460D4C-D217-46B4-80B6-B5ED50BD7CF5}',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{3F460D4C-D217-46B4-80B6-B5ED50BD7CF5}')
        $RegNameFound=0;
        $RegPublisherFound=0;
    }
    Process{
        Try{
            foreach($RegRoot in $RegRoots){
                if (Get-ItemProperty $RegRoot -Name DisplayName -ErrorAction SilentlyContinue){
                    If ($PSCmdlet.ShouldProcess("$($RegRoot)\DisplayName=$($Name)", "Set Registry Value")) {
                        Write-Verbose "Setting $($RegRoot)\DisplayName=$($Name)"
                        Set-ItemProperty $RegRoot -Name DisplayName -Value $Name -Confirm:$False
                        $RegNameFound++
                    }
                } ElseIf (Get-ItemProperty $RegRoot -Name  HiddenProductName -ErrorAction SilentlyContinue){
                    If ($PSCmdlet.ShouldProcess("$($RegRoot)\ HiddenProductName=$($Name)", "Set Registry Value")) {
                        Write-Verbose "Setting $($RegRoot)\ HiddenProductName=$($Name)"
                        Set-ItemProperty $RegRoot -Name  HiddenProductName -Value $Name -Confirm:$False
                        $RegNameFound++
                    }
                }
            }
        }
        Catch{
            Write-Error "ERROR: Line $(LINENUM): There was an error setting the registry key value. $($Error[0])" -ErrorAction Stop
        }
        If (($PublisherName)){
            Try{
                Foreach($RegRoot in $PublisherRegRoots){
                    If (Get-ItemProperty $RegRoot -Name Publisher -ErrorAction SilentlyContinue){
                        If ($PSCmdlet.ShouldProcess("$($RegRoot)\Publisher=$($PublisherName)", "Set Registry Value")) {
                            Write-Verbose "Setting $($RegRoot)\Publisher=$($PublisherName)"
                            Set-ItemProperty $RegRoot -Name Publisher -Value $PublisherName -Confirm:$False
                            $RegPublisherFound++
                        }
                    }
                }
            }
            Catch{
                Write-Error "ERROR: Line $(LINENUM): There was an error setting the registry key value. $($Error[0])" -ErrorAction Stop
            }
        }
    }
    End{
        If ($WhatIfPreference -ne $True) {
            If ($?){
                If ($RegNameFound -gt 0) {
                    Write-Output "LabTech is now listed as $($Name) in Add/Remove Programs."
                } Else {
                    Write-Warning "WARNING: Line $(LINENUM): LabTech was not found in installed software and the Name was not changed."
                }
                If (($PublisherName)){
                    If ($RegPublisherFound -gt 0) {
                        Write-Output "The Publisher is now listed as $($PublisherName)."
                    } Else {
                        Write-Warning "WARNING: Line $(LINENUM): LabTech was not found in installed software and the Publisher was not changed."
                    }
                }
            } Else {$Error[0]}
        }
    }
}
Function Show-CWAAAddRemove{
    [CmdletBinding(SupportsShouldProcess=$True)]
    [Alias('Show-LTAddRemove')]
    Param()
    Begin{
        Write-Debug "Starting $($myInvocation.InvocationName) at line $(LINENUM)"
        $RegRoots = ('HKLM:\SOFTWARE\Classes\Installer\Products\C4D064F3712D4B64086B5BDE05DBC75F',
        'HKLM:\SOFTWARE\Classes\Installer\Products\D1003A85576B76D45A1AF09A0FC87FAC')
        $PublisherRegRoots = ('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{58A3001D-B675-4D67-A5A1-0FA9F08CF7CA}',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{58A3001D-B675-4D67-A5A1-0FA9F08CF7CA}',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{3F460D4C-D217-46B4-80B6-B5ED50BD7CF5}',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{3F460D4C-D217-46B4-80B6-B5ED50BD7CF5}')
        $RegEntriesFound=0
        $RegEntriesChanged=0
    }
    Process{
        Try{
            Foreach($RegRoot in $RegRoots){
                If (Test-Path $RegRoot){
                    If (Get-ItemProperty $RegRoot -Name HiddenProductName -ErrorAction SilentlyContinue) {
                        If (!(Get-ItemProperty $RegRoot -Name ProductName -ErrorAction SilentlyContinue)) {
                            Write-Verbose "LabTech found with HiddenProductName value."
                            Try{
                                Rename-ItemProperty $RegRoot -Name HiddenProductName -NewName ProductName
                            }
                            Catch{
                                Write-Error "ERROR: Line $(LINENUM): There was an error renaming the registry value. $($Error[0])" -ErrorAction Stop
                            }
                        } Else {
                            Write-Verbose "LabTech found with unused HiddenProductName value."
                            Try{
                                Remove-ItemProperty $RegRoot -Name HiddenProductName -EA 0 -Confirm:$False -WhatIf:$False -Force
                            }
                            Catch{}
                        }
                    }
                }
            }
            Foreach($RegRoot in $PublisherRegRoots){
                If (Test-Path $RegRoot){
                    $RegKey=Get-Item $RegRoot -ErrorAction SilentlyContinue
                    If ($RegKey){
                        $RegEntriesFound++
                        If ($PSCmdlet.ShouldProcess("$($RegRoot)", "Set Registry Values to Show $($RegKey.GetValue('DisplayName'))")){
                            $RegEntriesChanged++
                            @('SystemComponent') | ForEach-Object {
                                If (($RegKey.GetValue("$($_)")) -eq 1) {
                                    Write-Verbose "Setting $($RegRoot)\$($_)=0"
                                    Set-ItemProperty $RegRoot -Name "$($_)" -Value 0 -Type DWord -WhatIf:$False -Confirm:$False -Verbose:$False
                                }
                            }
                        }
                    }
                }
            }
        }
        Catch{
            Write-Error "ERROR: Line $(LINENUM): There was an error setting the registry values. $($Error[0])" -ErrorAction Stop
        }
    }
    End{
        If ($WhatIfPreference -ne $True) {
            If ($?){
                If ($RegEntriesFound -gt 0 -and $RegEntriesChanged -eq $RegEntriesFound) {
                    Write-Output "LabTech is visible from Add/Remove Programs."
                } Else {
                    Write-Warning "WARNING: Line $(LINENUM): LabTech may not be visible from Add/Remove Programs."
                }
            }
            Else {$Error[0]}
        }
        Write-Debug "Exiting $($myInvocation.InvocationName) at line $(LINENUM)"
    }
}
Function Install-CWAA {
    [CmdletBinding(SupportsShouldProcess=$True,DefaultParameterSetName = 'deployment')]
    [Alias('Install-LTService')]
    Param(
        [Parameter(ParameterSetName = 'deployment')]
        [Parameter(ParameterSetName = 'installertoken')]
        [Parameter(ValueFromPipelineByPropertyName = $true, Mandatory=$True)]
        [string[]]$Server,
        [Parameter(ParameterSetName = 'deployment')]
        [Parameter(ValueFromPipelineByPropertyName = $True)]
        [AllowNull()]
        [Alias("Password")]
        [SecureString]$ServerPassword,
        [Parameter(ParameterSetName = 'installertoken')]
        [ValidatePattern('(?s:^[0-9a-z]+$)')]
        [string]$InstallerToken,
        [Parameter(ValueFromPipelineByPropertyName = $True)]
        [AllowNull()]
        [int]$LocationID,
        [Parameter(ValueFromPipelineByPropertyName = $True)]
        [AllowNull()]
        [int]$TrayPort,
        [Parameter()]
        [AllowNull()]
        [string]$Rename,
        [switch]$Hide,
        [switch]$SkipDotNet,
        [switch]$Force,
        [switch]$NoWait
    )
    Begin{
        Clear-Variable DotNET,OSVersion,PasswordArg,Result,logpath,logfile,curlog,installer,installerTest,installerResult,GoodServer,GoodTrayPort,TestTrayPort,Svr,SVer,SvrVer,SvrVerCheck,iarg,timeout,sw,tmpLTSI -EA 0 -WhatIf:$False -Confirm:$False #Clearing Variables for use
        Write-Debug "Starting $($myInvocation.InvocationName) at line $(LINENUM)"
        If (!($Force)) {
            If (Get-Service 'LTService','LTSvcMon' -ErrorAction SilentlyContinue) {
                If ($WhatIfPreference -ne $True) {
                    Write-Error "ERROR: Line $(LINENUM): Services are already installed." -ErrorAction Stop
                } Else {
                    Write-Error "ERROR: Line $(LINENUM): What if: Stopping: Services are already installed." -ErrorAction Stop
                }
            }
        }
        If (-not ([bool](([System.Security.Principal.WindowsIdentity]::GetCurrent()|Select-Object -Expand groups -EA 0) -match 'S-1-5-32-544'))) {
            Throw "Needs to be ran as Administrator"
        }
        If (!$SkipDotNet){
            $DotNET = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP' -recurse -EA 0 | Get-ItemProperty -name Version,Release -EA 0 | Where-Object { $_.PSChildName -match '^(?!S)\p{L}'} | Select-Object -ExpandProperty Version -EA 0
            If (-not ($DotNet -like '3.5.*')){
                Write-Output ".NET Framework 3.5 installation needed."
                #Install-WindowsFeature Net-Framework-Core
                $OSVersion = [System.Environment]::OSVersion.Version
                If ([version]$OSVersion -gt [version]'6.2'){
                    Try{
                        If ( $PSCmdlet.ShouldProcess('NetFx3', 'Enable-WindowsOptionalFeature') ) {
                            $Install = Get-WindowsOptionalFeature -Online -FeatureName 'NetFx3'
                            If (!($Install.State -eq 'EnablePending')) {
                                $Install = Enable-WindowsOptionalFeature -Online -FeatureName 'NetFx3' -All -NoRestart
                            }
                            If ($Install.RestartNeeded -or $Install.State -eq 'EnablePending') {
                                Write-Output ".NET Framework 3.5 installed but a reboot is needed."
                            }
                        }
                    }
                    Catch{
                        Write-Error "ERROR: Line $(LINENUM): .NET 3.5 install failed." -ErrorAction Continue
                        If (!($Force)) { Write-Error ("Line $(LINENUM):",$Install) -ErrorAction Stop }
                    }
                }
                ElseIf ([version]$OSVersion -gt [version]'6.1'){
                    If ( $PSCmdlet.ShouldProcess("NetFx3", "Add Windows Feature") ) {
                        Try {$Result=& "${env:windir}\system32\Dism.exe" /English /NoRestart /Online /Enable-Feature /FeatureName:NetFx3 2>''}
                        Catch {Write-Output "Error calling Dism.exe."; $Result=$Null}
                        Try {$Result=& "${env:windir}\system32\Dism.exe" /English /Online /Get-FeatureInfo /FeatureName:NetFx3 2>''}
                        Catch {Write-Output "Error calling Dism.exe."; $Result=$Null}
                        If ($Result -contains 'State : Enabled'){
                            Write-Warning "WARNING: Line $(LINENUM): .Net Framework 3.5 has been installed and enabled."
                        } ElseIf ($Result -contains 'State : Enable Pending'){
                            Write-Warning "WARNING: Line $(LINENUM): .Net Framework 3.5 installed but a reboot is needed."
                        } Else {
                            Write-Error "ERROR: Line $(LINENUM): .NET Framework 3.5 install failed." -ErrorAction Continue
                            If (!($Force)) { Write-Error ("ERROR: Line $(LINENUM):",$Result) -ErrorAction Stop }
                        }
                    }
                }
                $DotNET = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP' -recurse | Get-ItemProperty -name Version -EA 0 | Where-Object{ $_.PSChildName -match '^(?!S)\p{L}'} | Select-Object -ExpandProperty Version
            }
            If (-not ($DotNet -like '3.5.*')){
                If (($Force)) {
                    If ($DotNet -match '(?m)^[2-4].\d'){
                        Write-Error "ERROR: Line $(LINENUM): .NET 3.5 is not detected and could not be installed." -ErrorAction Continue
                    } Else {
                        Write-Error "ERROR: Line $(LINENUM): .NET 2.0 or greater is not detected and could not be installed." -ErrorAction Stop
                    }
                } Else {
                    Write-Error "ERROR: Line $(LINENUM): .NET 3.5 is not detected and could not be installed." -ErrorAction Stop
                }
            }
        }
        $InstallBase="${env:windir}\Temp\LabTech"
        $InstallMSI='Agent_Install.msi'
        $logfile = "LTAgentInstall"
        $curlog = "$($InstallBase)\$($logfile).log"
        If (-not (Test-Path -PathType Container -Path "$InstallBase\Installer" )){
            New-Item "$InstallBase\Installer" -type directory -ErrorAction SilentlyContinue | Out-Null
        }
        If ((Test-Path -PathType Leaf -Path $($curlog))){
            If ($PSCmdlet.ShouldProcess("$($curlog)","Rotate existing log file")){
                Get-Item -LiteralPath $curlog -EA 0 | Where-Object {$_} | Foreach-Object {
                    Rename-Item -Path $($_|Select-Object -Expand FullName -EA 0) -NewName "$($logfile)-$(Get-Date $($_|Select-Object -Expand LastWriteTime -EA 0) -Format 'yyyyMMddHHmmss').log" -Force -Confirm:$False -WhatIf:$False
                    Remove-Item -Path $($_|Select-Object -Expand FullName -EA 0) -Force -EA 0 -Confirm:$False -WhatIf:$False
                }
            }
        }
    }
    Process{
        If (-not ($LocationID -or $PSCmdlet.ParameterSetName -eq 'installertoken')){
            $LocationID = "1"
        }
        If (-not ($TrayPort) -or -not ($TrayPort -ge 1 -and $TrayPort -le 65535)){
            $TrayPort = "42000"
        }
        $Server=ForEach ($Svr in $Server) {If ($Svr -notmatch 'https?://.+') {"https://$($Svr)"}; $Svr}
        ForEach ($Svr in $Server) {
            If (-not ($GoodServer)) {
                If ($Svr -match '^(https?://)?(([12]?[0-9]{1,2}\.){3}[12]?[0-9]{1,2}|[a-z0-9][a-z0-9_-]*(\.[a-z0-9][a-z0-9_-]*)*)$') {
                    If ($Svr -notmatch 'https?://.+') {$Svr = "http://$($Svr)"}
                    Try {
                        If ($PSCmdlet.ParameterSetName -eq 'installertoken') {
                            Write-Debug "Line $(LINENUM): Skipping Server Version Check. Using Installer Token for download."
                            $installer = "$($Svr)/LabTech/Deployment.aspx?InstallerToken=$InstallerToken"
                        } Else {
                            $SvrVerCheck = "$($Svr)/LabTech/Agent.aspx"
                            Write-Debug "Line $(LINENUM): Testing Server Response and Version: $SvrVerCheck"
                            $SvrVer = $Script:LTServiceNetWebClient.DownloadString($SvrVerCheck)
                            Write-Debug "Line $(LINENUM): Raw Response: $SvrVer"
                            $SVer = $SvrVer|select-string -pattern '(?<=[|]{6})[0-9]{1,3}\.[0-9]{1,3}'|ForEach-Object {$_.matches}|Select-Object -Expand value -EA 0
                            If ($Null -eq $SVer) {
                                Write-Verbose "Unable to test version response from $($Svr)."
                                Continue
                            }
                            If ([System.Version]$SVer -ge [System.Version]'110.374') {
                                #New Style Download Link starting with LT11 Patch 13 - Direct Location Targeting is no longer available
                                $installer = "$($Svr)/LabTech/Deployment.aspx?Probe=1&installType=msi&MSILocations=1"
                            } Else {
                                #Original URL
                                Write-Warning 'Update your damn server!'
                                $installer = "$($Svr)/LabTech/Deployment.aspx?Probe=1&installType=msi&MSILocations=$LocationID"
                            }
                            # Vuln test June 10, 2020: ConnectWise Automate API Vulnerability - Only test if version is below known minimum.
                            Try{
                                If ([System.Version]$SVer -lt [System.Version]'200.197' -or !$ServerPassword) {
                                    $HTTP_Request = [System.Net.WebRequest]::Create("$($Svr)/LabTech/Deployment.aspx")
                                    If ($HTTP_Request.GetResponse().StatusCode -eq 'OK') {
                                        $Message = @('Your server is vulnerable!!')
                                        $Message += 'https://docs.connectwise.com/ConnectWise_Automate/ConnectWise_Automate_Supportability_Statements/Supportability_Statement%3A_ConnectWise_Automate_Mitigation_Steps'
                                        Write-Warning $($Message | Out-String)
                                    }
                                }
                            }
                            Catch {
                                If (!$ServerPassword) {
                                    Write-Error 'Anonymous downloads are not allowed. ServerPassword or InstallerToken may be needed.'
                                    Continue
                                }
                            }
                            If ($ServerPassword) { $installer = "$($Svr)/LabTech/Service/LabTechRemoteAgent.msi" }
                        }
                        If ( $PSCmdlet.ShouldProcess($installer, "DownloadFile") ) {
                            Write-Debug "Line $(LINENUM): Downloading $InstallMSI from $installer"
                            $Script:LTServiceNetWebClient.DownloadFile($installer,"$InstallBase\Installer\$InstallMSI")
                            If((Test-Path "$InstallBase\Installer\$InstallMSI") -and  !((Get-Item "$InstallBase\Installer\$InstallMSI" -EA 0).length/1KB -gt 1234)) {
                                Write-Warning "WARNING: Line $(LINENUM): $InstallMSI size is below normal. Removing suspected corrupt file."
                                Remove-Item "$InstallBase\Installer\$InstallMSI" -ErrorAction SilentlyContinue -Force -Confirm:$False
                                Continue
                            }
                        }
                        If ($WhatIfPreference -eq $True) {
                            $GoodServer = $Svr
                        } ElseIf (Test-Path "$InstallBase\Installer\$InstallMSI") {
                            $GoodServer = $Svr
                            Write-Verbose "$InstallMSI downloaded successfully from server $($Svr)."
                        } Else {
                            Write-Warning "WARNING: Line $(LINENUM): Error encountered downloading from $($Svr). No installation file was received."
                            Continue
                        }
                    }
                    Catch {
                        Write-Warning "WARNING: Line $(LINENUM): Error encountered downloading from $($Svr)."
                        Continue
                    }
                } Else {
                    Write-Warning "WARNING: Line $(LINENUM): Server address $($Svr) is not formatted correctly. Example: https://lt.domain.com"
                }
            } Else {
                Write-Debug "Line $(LINENUM): Server $($GoodServer) has been selected."
                Write-Verbose "Server has already been selected - Skipping $($Svr)."
            }
        }
    }
    End{
        If ($GoodServer) {
            If ( $WhatIfPreference -eq $True -and (Get-PSCallStack)[1].Command -eq 'Redo-LTService' ) {
                Write-Debug "Line $(LINENUM): Skipping Preinstall Check: Called by Redo-LTService and ""-WhatIf=`$True"""
            } Else {
                If ((Test-Path "${env:windir}\ltsvc" -EA 0) -or (Test-Path "${env:windir}\temp\_ltupdate" -EA 0) -or (Test-Path registry::HKLM\Software\LabTech\Service -EA 0) -or (Test-Path registry::HKLM\Software\WOW6432Node\Labtech\Service -EA 0)){
                    Write-Warning "WARNING: Line $(LINENUM): Previous installation detected. Calling Uninstall-LTService"
                    Uninstall-LTService -Server $GoodServer -Force
                    Start-Sleep 10
                }
            }
            If ($WhatIfPreference -ne $True) {
                $GoodTrayPort=$Null;
                $TestTrayPort=$TrayPort;
                For ($i=0; $i -le 10; $i++) {
                    If (-not ($GoodTrayPort)) {
                        If (-not (Test-LTPorts -TrayPort $TestTrayPort -Quiet)){
                            $TestTrayPort++;
                            If ($TestTrayPort -gt 42009) {$TestTrayPort=42000}
                        } Else {
                            $GoodTrayPort=$TestTrayPort
                        }
                    }
                }
                If ($GoodTrayPort -and $GoodTrayPort -ne $TrayPort -and $GoodTrayPort -ge 1 -and $GoodTrayPort -le 65535) {
                    Write-Verbose "TrayPort $($TrayPort) is in use. Changing TrayPort to $($GoodTrayPort)"
                    $TrayPort=$GoodTrayPort
                }
                Write-Output "Starting Install."
            }
            #Build parameter string
            $iarg =(@(
                "/i `"$InstallBase\Installer\$InstallMSI`"",
                "SERVERADDRESS=$GoodServer",
                $(If ($ServerPassword -and $ServerPassword -match '.') {"SERVERPASS=""$ServerPassword"""} Else {""}),
                $(If ($LocationID -and $LocationID -match '^\d+$') {"LOCATION=$LocationID"} Else {""}),
                $(If ($TrayPort -and $TrayPort -ne 42000) {"SERVICEPORT=$TrayPort"} Else {""}),
                "/qn",
                "/l ""$InstallBase\$logfile.log""") | Where-Object {$_}) -join ' '
            Try{
                If ( $PSCmdlet.ShouldProcess("msiexec.exe $($iarg)", "Execute Install") ) {
                    $InstallAttempt=0
                    Do {
                        If ($InstallAttempt -gt 0 ) {
                            Write-Warning "WARNING: Line $(LINENUM): Service Failed to Install. Retrying in 30 seconds." -WarningAction 'Continue'
                            $timeout = new-timespan -Seconds 30
                            $sw = [diagnostics.stopwatch]::StartNew()
                            Do {
                                Start-Sleep 5
                                $svcRun = ('LTService') | Get-Service -EA 0 | Measure-Object | Select-Object -Expand Count
                            } Until ($sw.elapsed -gt $timeout -or $svcRun -eq 1)
                            $sw.Stop()
                        }
                        $InstallAttempt++
                        $svcRun = ('LTService') | Get-Service -EA 0 | Measure-Object | Select-Object -Expand Count
                        If ($svcRun -eq 0) {
                            Write-Verbose "Launching Installation Process: msiexec.exe $(($iarg -join ''))"
                            Start-Process -Wait -FilePath "${env:windir}\system32\msiexec.exe" -ArgumentList $iarg -WorkingDirectory $env:TEMP
                            Start-Sleep 5
                        }
                        $svcRun = ('LTService') | Get-Service -EA 0 | Measure-Object | Select-Object -Expand Count
                    } Until ($InstallAttempt -ge 3 -or $svcRun -eq 1)
                    If ($svcRun -eq 0) {
                        Write-Error "ERROR: Line $(LINENUM): LTService was not installed. Installation failed."
                        Return
                    }
                }
                If (($Script:LTProxy.Enabled) -eq $True) {
                    Write-Verbose "Proxy Configuration Needed. Applying Proxy Settings to Agent Installation."
                    If ( $PSCmdlet.ShouldProcess($Script:LTProxy.ProxyServerURL, "Configure Agent Proxy") ) {
                        $svcRun = ('LTService') | Get-Service -EA 0 | Where-Object {$_.Status -eq 'Running'} | Measure-Object | Select-Object -Expand Count
                        If ($svcRun -ne 0) {
                            $timeout = new-timespan -Minutes 2
                            $sw = [diagnostics.stopwatch]::StartNew()
                            Write-Host -NoNewline "Waiting for Service to Start."
                            Do {
                                Write-Host -NoNewline '.'
                                Start-Sleep 2
                                $svcRun = ('LTService') | Get-Service -EA 0 | Where-Object {$_.Status -eq 'Running'} | Measure-Object | Select-Object -Expand Count
                            } Until ($sw.elapsed -gt $timeout -or $svcRun -eq 1)
                            Write-Host ""
                            $sw.Stop()
                            If ($svcRun -eq 1) {
                                Write-Debug "Line $(LINENUM): LTService Initial Startup Successful."
                            } Else {
                                Write-Debug "Line $(LINENUM): LTService Initial Startup failed to complete within expected period."
                            }
                        }
                        Set-LTProxy -ProxyServerURL $Script:LTProxy.ProxyServerURL -ProxyUsername $Script:LTProxy.ProxyUsername -ProxyPassword $Script:LTProxy.ProxyPassword -Confirm:$False -WhatIf:$False
                    }
                } Else {
                    Write-Verbose "No Proxy Configuration has been specified - Continuing."
                }
                If (!($NoWait) -and $PSCmdlet.ShouldProcess("LTService","Monitor For Successful Agent Registration") ) {
                    $timeout = new-timespan -Minutes 3
                    $sw = [diagnostics.stopwatch]::StartNew()
                    Write-Host -NoNewline "Waiting for agent to register."
                    Do {
                        Write-Host -NoNewline '.'
                        Start-Sleep 5
                        $tmpLTSI = (Get-LTServiceInfo -EA 0 -Verbose:$False -WhatIf:$False -Confirm:$False -Debug:$False|Select-Object -Expand 'ID' -EA 0)
                    } Until ($sw.elapsed -gt $timeout -or $tmpLTSI -ge 1)
                    Write-Host ""
                    $sw.Stop()
                    Write-Verbose "Completed wait for LabTech Installation after $(([int32]$sw.Elapsed.TotalSeconds).ToString()) seconds."
                    $Null=Get-LTProxy -ErrorAction Continue
                }
                If ($Hide) {Hide-LTAddRemove}
            }
            Catch{
                Write-Error "ERROR: Line $(LINENUM): There was an error during the install process. $($Error[0])"
                Return
            }
            If ($WhatIfPreference -ne $True) {
                #Cleanup Install files
                Remove-Item "$InstallBase\Installer\$InstallMSI" -ErrorAction SilentlyContinue -Force -Confirm:$False
                @($curlog,"${env:windir}\LTSvc\Install.log") | Foreach-Object {
                    If ((Test-Path -PathType Leaf -LiteralPath $($_))) {
                        $logcontents=Get-Content -Path $_
                        $logcontents=$logcontents -replace '(?<=PreInstallPass:[^\r\n]+? (?:result|value)): [^\r\n]+',': <REDACTED>'
                        If ($logcontents) {Set-Content -Path $_ -Value $logcontents -Force -Confirm:$False}
                    }
                }
                $tmpLTSI = Get-LTServiceInfo -EA 0 -Verbose:$False -WhatIf:$False -Confirm:$False -Debug:$False
                If (($tmpLTSI)) {
                    If (($tmpLTSI|Select-Object -Expand 'ID' -EA 0) -ge 1) {
                        Write-Output "LabTech has been installed successfully. Agent ID: $($tmpLTSI|Select-Object -Expand 'ID' -EA 0) LocationID: $($tmpLTSI|Select-Object -Expand 'LocationID' -EA 0)"
                    } ElseIf (!($NoWait)) {
                        Write-Error "ERROR: Line $(LINENUM): LabTech installation completed but Agent failed to register within expected period." -ErrorAction Continue
                    } Else {
                        Write-Warning "WARNING: Line $(LINENUM): LabTech installation completed but Agent did not yet register." -WarningAction Continue
                    }
                } Else {
                    If (($Error)) {
                        Write-Error "ERROR: Line $(LINENUM): There was an error installing LabTech. Check the log, $InstallBase\$logfile.log $($Error[0])"
                        Return
                    } ElseIf (!($NoWait)) {
                        Write-Error "ERROR: Line $(LINENUM): There was an error installing LabTech. Check the log, $InstallBase\$logfile.log"
                        Return
                    } Else {
                        Write-Warning "WARNING: Line $(LINENUM): LabTech installation may not have succeeded." -WarningAction Continue
                    }
                }
            }
            If (($Rename) -and $Rename -notmatch 'False'){ Rename-LTAddRemove -Name $Rename }
        } ElseIf ( $WhatIfPreference -ne $True ) {
            Write-Error "ERROR: Line $(LINENUM): No valid server was reached to use for the install."
        }
        Write-Debug "Exiting $($myInvocation.InvocationName) at line $(LINENUM)"
    }
}
Function Redo-CWAA{
    [CmdletBinding(SupportsShouldProcess=$True)]
    [Alias('Reinstall-CWAA','Redo-LTService','Reinstall-LTService')]
    Param(
        [Parameter(ValueFromPipelineByPropertyName = $True, ValueFromPipeline=$True)]
        [AllowNull()]
        [string[]]$Server,
        [Parameter(ParameterSetName = 'deployment')]
        [Parameter(ValueFromPipelineByPropertyName = $True, ValueFromPipeline=$True)]
        [Alias("Password")]
        [SecureString]$ServerPassword,
        [Parameter(ParameterSetName = 'installertoken')]
        [ValidatePattern('(?s:^[0-9a-z]+$)')]
        [string]$InstallerToken,
        [Parameter(ValueFromPipelineByPropertyName = $True)]
        [AllowNull()]
        [string]$LocationID,
        [switch]$Backup,
        [switch]$Hide,
        [Parameter()]
        [AllowNull()]
        [string]$Rename,
        [switch]$SkipDotNet,
        [switch]$Force
    )
    Begin{
        Clear-Variable PasswordArg, RenameArg, Svr, ServerList, Settings -EA 0 -WhatIf:$False -Confirm:$False #Clearing Variables for use
        Write-Debug "Starting $($myInvocation.InvocationName) at line $(LINENUM)"
        # Gather install stats from registry or backed up settings
        Try {
            $Settings = Get-CWAAInfo -EA 0 -Verbose:$False -WhatIf:$False -Confirm:$False
            If ($Null -ne $Settings) {
                If (($Settings|Select-Object -Expand Probe -EA 0) -eq '1') {
                    If ($Force -eq $True) {
                        Write-Output "Probe Agent Detected. Re-Install Forced."
                    } Else {
                        If ($WhatIfPreference -ne $True) {
                            Write-Error -Exception [System.OperationCanceledException]"ERROR: Line $(LINENUM): Probe Agent Detected. Re-Install Denied." -ErrorAction Stop
                        } Else {
                            Write-Error -Exception [System.OperationCanceledException]"What If: Line $(LINENUM): Probe Agent Detected. Re-Install Denied." -ErrorAction Stop
                        }
                    }
                }
            }
        } Catch {
            Write-Debug "Line $(LINENUM): Failed to retrieve current Agent Settings."
        }
        If ($Null -eq $Settings) {
            Write-Debug "Line $(LINENUM): Unable to retrieve current Agent Settings. Testing for Backup Settings"
            Try {
                $Settings = Get-CWAAInfoBackup -EA 0
            } Catch {}
        }
        $ServerList=@()
    }
    Process{
        if (-not ($Server)){
            if ($Settings){
                $Server = $Settings|Select-Object -Expand 'Server' -EA 0
            }
            if (-not ($Server)){
                $Server = Read-Host -Prompt 'Provide the URL to your LabTech server (https://lt.domain.com):'
            }
        }
        if (-not ($LocationID)){
            if ($Settings){
                $LocationID = $Settings|Select-Object -Expand LocationID -EA 0
            }
            if (-not ($LocationID)){
                $LocationID = Read-Host -Prompt 'Provide the LocationID'
            }
        }
        if (-not ($LocationID)){
            $LocationID = "1"
        }
        $ServerList += $Server
    }
    End{
        If ($Backup){
            If ( $PSCmdlet.ShouldProcess("LTService","Backup Current Service Settings") ) {
                New-CWAABackup
            }
        }
        $RenameArg=''
        If ($Rename){
            $RenameArg = "-Rename $Rename"
        }
        If ($PSCmdlet.ParameterSetName -eq 'installertoken') {
            $PasswordPresent = "-InstallerToken 'REDACTED'"
        } ElseIf (($ServerPassword)){
            $PasswordPresent = "-Password 'REDACTED'"
        }
        Write-Output "Reinstalling LabTech with the following information, -Server $($ServerList -join ',') $PasswordPresent -LocationID $LocationID $RenameArg"
        Write-Verbose "Starting: UnInstall-CWAA -Server $($ServerList -join ',')"
        Try{
            Uninstall-CWAA -Server $ServerList -ErrorAction Stop -Force
        }
        Catch{
            Write-Error "ERROR: Line $(LINENUM): There was an error during the reinstall process while uninstalling. $($Error[0])" -ErrorAction Stop
        }
        Finally{
            If ($WhatIfPreference -ne $True) {
                Write-Verbose "Waiting 20 seconds for prior uninstall to settle before starting Install."
                Start-Sleep 20
            }
        }
        Write-Verbose "Starting: Install-CWAA -Server $($ServerList -join ',') $PasswordPresent -LocationID $LocationID -Hide:`$$($Hide) $RenameArg"
        Try{
            If ($PSCmdlet.ParameterSetName -ne 'installertoken') {
                Install-CWAA -Server $ServerList -ServerPassword $ServerPassword -LocationID $LocationID -Hide:$Hide -Rename $Rename -SkipDotNet:$SkipDotNet -Force
            } Else {
                Install-CWAA -Server $ServerList -InstallerToken $InstallerToken -LocationID $LocationID -Hide:$Hide -Rename $Rename -SkipDotNet:$SkipDotNet -Force
            }
        }
        Catch{
            Write-Error "ERROR: Line $(LINENUM): There was an error during the reinstall process while installing. $($Error[0])" -ErrorAction Stop
        }
        If (!($?)){
            $($Error[0])
        }
        Write-Debug "Exiting $($myInvocation.InvocationName) at line $(LINENUM)"
    }
}
Function Uninstall-CWAA{
    [CmdletBinding(SupportsShouldProcess=$True)]
    [Alias('Uninstall-LTService')]
    Param(
        [Parameter(ValueFromPipelineByPropertyName = $true)]
        [AllowNull()]
        [string[]]$Server,
        [Parameter(ValueFromPipelineByPropertyName = $true)]
        [switch]$Backup,
        [switch]$Force
    )
    Begin{
        Clear-Variable Executables,BasePath,reg,regs,installer,installerTest,installerResult,LTSI,uninstaller,uninstallerTest,uninstallerResult,xarg,Svr,SVer,SvrVer,SvrVerCheck,GoodServer,AlternateServer,Item -EA 0 -WhatIf:$False -Confirm:$False #Clearing Variables for use
        Write-Debug "Starting $($myInvocation.InvocationName) at line $(LINENUM)"
        If (-not ([bool](([System.Security.Principal.WindowsIdentity]::GetCurrent()|Select-Object -Expand groups -EA 0) -match 'S-1-5-32-544'))) {
            Throw "Line $(LINENUM): Needs to be ran as Administrator"
        }
        $LTSI = Get-CWAAInfo -EA 0 -Verbose:$False -WhatIf:$False -Confirm:$False -Debug:$False
        If (($LTSI) -and ($LTSI|Select-Object -Expand Probe -EA 0) -eq '1') {
            If ($Force -eq $True) {
                Write-Output "Probe Agent Detected. UnInstall Forced."
            } Else {
                Write-Error -Exception [System.OperationCanceledException]"Line $(LINENUM): Probe Agent Detected. UnInstall Denied." -ErrorAction Stop
            }
        }
        If ($Backup){
            If ( $PSCmdlet.ShouldProcess("LTService","Backup Current Service Settings") ) {
                New-CWAABackup
            }
        }
        $BasePath = $(Get-CWAAInfo -EA 0 -Verbose:$False -WhatIf:$False -Confirm:$False -Debug:$False|Select-Object -Expand BasePath -EA 0)
        If (-not ($BasePath)) {$BasePath = "$env:windir\LTSVC"}
        New-PSDrive HKU Registry HKEY_USERS -ErrorAction SilentlyContinue -WhatIf:$False -Confirm:$False -Debug:$False| Out-Null
        $regs = @( 'Registry::HKEY_LOCAL_MACHINE\Software\LabTechMSP',
            'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\LabTech\Service',
            'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\LabTech\LabVNC',
            'Registry::HKEY_LOCAL_MACHINE\Software\Wow6432Node\LabTech\Service',
            'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\Installer\Products\D1003A85576B76D45A1AF09A0FC87FAC',
            'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\Installer\Products\D1003A85576B76D45A1AF09A0FC87FAC',
            'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\Managed\\Installer\Products\C4D064F3712D4B64086B5BDE05DBC75F',
            'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\D1003A85576B76D45A1AF09A0FC87FAC\InstallProperties',
            'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{58A3001D-B675-4D67-A5A1-0FA9F08CF7CA}',
            'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{3426921d-9ad5-4237-9145-f15dee7e3004}',
            'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\Appmgmt\{40bf8c82-ed0d-4f66-b73e-58a3d7ab6582}',
            'Registry::HKEY_CLASSES_ROOT\Installer\Dependencies\{3426921d-9ad5-4237-9145-f15dee7e3004}',
            'Registry::HKEY_CLASSES_ROOT\Installer\Dependencies\{3F460D4C-D217-46B4-80B6-B5ED50BD7CF5}',
            'Registry::HKEY_CLASSES_ROOT\Installer\Products\C4D064F3712D4B64086B5BDE05DBC75F',
            'Registry::HKEY_CLASSES_ROOT\Installer\Products\D1003A85576B76D45A1AF09A0FC87FAC',
            'Registry::HKEY_CLASSES_ROOT\CLSID\{09DF1DCA-C076-498A-8370-AD6F878B6C6A}',
            'Registry::HKEY_CLASSES_ROOT\CLSID\{15DD3BF6-5A11-4407-8399-A19AC10C65D0}',
            'Registry::HKEY_CLASSES_ROOT\CLSID\{3C198C98-0E27-40E4-972C-FDC656EC30D7}',
            'Registry::HKEY_CLASSES_ROOT\CLSID\{459C65ED-AA9C-4CF1-9A24-7685505F919A}',
            'Registry::HKEY_CLASSES_ROOT\CLSID\{7BE3886B-0C12-4D87-AC0B-09A5CE4E6BD6}',
            'Registry::HKEY_CLASSES_ROOT\CLSID\{7E092B5C-795B-46BC-886A-DFFBBBC9A117}',
            'Registry::HKEY_CLASSES_ROOT\CLSID\{9D101D9C-18CC-4E78-8D78-389E48478FCA}',
            'Registry::HKEY_CLASSES_ROOT\CLSID\{B0B8CDD6-8AAA-4426-82E9-9455140124A1}',
            'Registry::HKEY_CLASSES_ROOT\CLSID\{B1B00A43-7A54-4A0F-B35D-B4334811FAA4}',
            'Registry::HKEY_CLASSES_ROOT\CLSID\{BBC521C8-2792-43FE-9C91-CCA7E8ACBCC9}',
            'Registry::HKEY_CLASSES_ROOT\CLSID\{C59A1D54-8CD7-4795-AEDD-F6F6E2DE1FE7}',
            'Registry::HKEY_CLASSES_ROOT\Installer\Products\C4D064F3712D4B64086B5BDE05DBC75F',
            'Registry::HKEY_CLASSES_ROOT\Installer\Products\D1003A85576B76D45A1AF09A0FC87FAC',
            'Registry::HKEY_CURRENT_USER\SOFTWARE\LabTech\Service',
            'Registry::HKEY_CURRENT_USER\SOFTWARE\LabTech\LabVNC',
            'Registry::HKEY_CURRENT_USER\Software\Microsoft\Installer\Products\C4D064F3712D4B64086B5BDE05DBC75F',
            'HKU:\*\Software\Microsoft\Installer\Products\C4D064F3712D4B64086B5BDE05DBC75F'
        )
        If ($WhatIfPreference -ne $True) {
            #Cleanup previous uninstallers
            Remove-Item 'Uninstall.exe','Uninstall.exe.config' -ErrorAction SilentlyContinue -Force -Confirm:$False
            New-Item "$env:windir\temp\LabTech\Installer" -type directory -ErrorAction SilentlyContinue | Out-Null
        }
        $xarg = "/x ""$($env:windir)\temp\LabTech\Installer\Agent_Install.msi"" /qn"
    }
    Process{
        If (-not ($Server)){
            $Server = Get-CWAAInfo -EA 0 -Verbose:$False -WhatIf:$False -Confirm:$False -Debug:$False|Select-Object -Expand 'Server' -EA 0
        }
        If (-not ($Server)){
            $Server = Read-Host -Prompt 'Provide the URL to your LabTech server (https://lt.domain.com):'
        }
        $Server=ForEach ($Svr in $Server) {If ($Svr -notmatch 'https?://.+') {"https://$($Svr)"}; $Svr}
        ForEach ($Svr in $Server) {
            If (-not ($GoodServer)) {
                If ($Svr -match '^(https?://)?(([12]?[0-9]{1,2}\.){3}[12]?[0-9]{1,2}|[a-z0-9][a-z0-9_-]*(\.[a-z0-9][a-z0-9_-]*)*)$') {
                    Try{
                        If ($Svr -notmatch 'https?://.+') {$Svr = "http://$($Svr)"}
                        $SvrVerCheck = "$($Svr)/Labtech/Agent.aspx"
                        Write-Debug "Line $(LINENUM): Testing Server Response and Version: $SvrVerCheck"
                        $SvrVer = $Script:LTServiceNetWebClient.DownloadString($SvrVerCheck)
                        Write-Debug "Line $(LINENUM): Raw Response: $SvrVer"
                        $SVer = $SvrVer|select-string -pattern '(?<=[|]{6})[0-9]{1,3}\.[0-9]{1,3}'|ForEach-Object {$_.matches}|Select-Object -Expand value -EA 0
                        If ($Null -eq ($SVer)) {
                            Write-Verbose "Unable to test version response from $($Svr)."
                            Continue
                        }
                        $installer = "$($Svr)/LabTech/Service/LabTechRemoteAgent.msi"
                        $installerTest = [System.Net.WebRequest]::Create($installer)
                        If (($Script:LTProxy.Enabled) -eq $True) {
                            Write-Debug "Line $(LINENUM): Proxy Configuration Needed. Applying Proxy Settings to request."
                            $installerTest.Proxy=$Script:LTWebProxy
                        }
                        $installerTest.KeepAlive=$False
                        $installerTest.ProtocolVersion = '1.0'
                        $installerResult = $installerTest.GetResponse()
                        $installerTest.Abort()
                        If ($installerResult.StatusCode -ne 200) {
                            Write-Warning "WARNING: Line $(LINENUM): Unable to download Agent_Install.msi from server $($Svr)."
                            Continue
                        }
                        Else {
                            If ($PSCmdlet.ShouldProcess("$installer", "DownloadFile")) {
                                Write-Debug "Line $(LINENUM): Downloading Agent_Install.msi from $installer"
                                $Script:LTServiceNetWebClient.DownloadFile($installer,"$env:windir\temp\LabTech\Installer\Agent_Install.msi")
                                If ((Test-Path "$env:windir\temp\LabTech\Installer\Agent_Install.msi")) {
                                    If (!((Get-Item "$env:windir\temp\LabTech\Installer\Agent_Install.msi" -EA 0).length/1KB -gt 1234)) {
                                        Write-Warning "WARNING: Line $(LINENUM): Agent_Install.msi size is below normal. Removing suspected corrupt file."
                                        Remove-Item "$env:windir\temp\LabTech\Installer\Agent_Install.msi" -ErrorAction SilentlyContinue -Force -Confirm:$False
                                        Continue
                                    } Else {
                                        $AlternateServer = $Svr
                                    }
                                }
                            }
                        }
                        #Using $SVer results gathered above.
                        If ([System.Version]$SVer -ge [System.Version]'110.374') {
                            #New Style Download Link starting with LT11 Patch 13 - The Agent Uninstaller URI has changed.
                            $uninstaller = "$($Svr)/LabTech/Service/LabUninstall.exe"
                        } Else {
                            #Original Uninstaller URL
                            $uninstaller = "$($Svr)/LabTech/Service/LabUninstall.exe"
                        }
                        $uninstallerTest = [System.Net.WebRequest]::Create($uninstaller)
                        If (($Script:LTProxy.Enabled) -eq $True) {
                            Write-Debug "Line $(LINENUM): Proxy Configuration Needed. Applying Proxy Settings to request."
                            $uninstallerTest.Proxy=$Script:LTWebProxy
                        }
                        $uninstallerTest.KeepAlive=$False
                        $uninstallerTest.ProtocolVersion = '1.0'
                        $uninstallerResult = $uninstallerTest.GetResponse()
                        $uninstallerTest.Abort()
                        If ($uninstallerResult.StatusCode -ne 200) {
                            Write-Warning "WARNING: Line $(LINENUM): Unable to download Agent_Uninstall from server."
                            Continue
                        } Else {
                            #Download Agent_Uninstall.exe
                            If ($PSCmdlet.ShouldProcess("$uninstaller", "DownloadFile")) {
                                Write-Debug "Line $(LINENUM): Downloading Agent_Uninstall.exe from $uninstaller"
                                $Script:LTServiceNetWebClient.DownloadFile($uninstaller,"$($env:windir)\temp\Agent_Uninstall.exe")
                                If ((Test-Path "$($env:windir)\temp\Agent_Uninstall.exe") -and !((Get-Item "$($env:windir)\temp\Agent_Uninstall.exe" -EA 0).length/1KB -gt 80)) {
                                    Write-Warning "WARNING: Line $(LINENUM): Agent_Uninstall.exe size is below normal. Removing suspected corrupt file."
                                    Remove-Item "$($env:windir)\temp\Agent_Uninstall.exe" -ErrorAction SilentlyContinue -Force -Confirm:$False
                                    Continue
                                }
                            }
                        }
                        If ($WhatIfPreference -eq $True) {
                            $GoodServer = $Svr
                        } ElseIf ((Test-Path "$env:windir\temp\LabTech\Installer\Agent_Install.msi") -and (Test-Path "$($env:windir)\temp\Agent_Uninstall.exe")) {
                            $GoodServer = $Svr
                            Write-Verbose "Successfully downloaded files from $($Svr)."
                        } Else {
                            Write-Warning "WARNING: Line $(LINENUM): Error encountered downloading from $($Svr). Uninstall file(s) could not be received."
                            Continue
                        }
                    }
                    Catch {
                        Write-Warning "WARNING: Line $(LINENUM): Error encountered downloading from $($Svr)."
                        Continue
                    }
                } Else {
                    Write-Verbose "Server address $($Svr) is not formatted correctly. Example: https://lt.domain.com"
                }
            } Else {
                Write-Debug "Line $(LINENUM): Server $($GoodServer) has been selected."
                Write-Verbose "Server has already been selected - Skipping $($Svr)."
            }
        }
    }
    End{
        If ($GoodServer -match 'https?://.+' -or $AlternateServer -match 'https?://.+') {
            Try{
                Write-Output "Starting Uninstall."
                Try { Stop-CWAA -ErrorAction SilentlyContinue } Catch {}
                #Kill all running processes from %ltsvcdir%
                If (Test-Path $BasePath){
                    $Executables = (Get-ChildItem $BasePath -Filter *.exe -Recurse -ErrorAction SilentlyContinue|Select-Object -Expand FullName)
                    If ($Executables) {
                        Write-Verbose "Terminating LabTech Processes from $($BasePath) if found running: $(($Executables) -replace [Regex]::Escape($BasePath),'' -replace '^\\','')"
                        Get-Process | Where-Object {$Executables -contains $_.Path } | ForEach-Object {
                            Write-Debug "Line $(LINENUM): Terminating Process $($_.ProcessName)"
                            $($_) | Stop-Process -Force -ErrorAction SilentlyContinue
                        }
                        Get-ChildItem $BasePath -Filter labvnc.exe -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction 0
                    }
                    If ($PSCmdlet.ShouldProcess("$($BasePath)\wodVPN.dll", "Unregister DLL")) {
                        #Unregister DLL
                        Write-Debug "Line $(LINENUM): Executing Command ""regsvr32.exe /u $($BasePath)\wodVPN.dll /s"""
                        Try {& "$env:windir\system32\regsvr32.exe" /u "$($BasePath)\wodVPN.dll" /s 2>''}
                        Catch {Write-Output "Error calling regsvr32.exe."}
                    }
                }
                If ($PSCmdlet.ShouldProcess("msiexec.exe $($xarg)", "Execute MSI Uninstall")) {
                    If ((Test-Path "$($env:windir)\temp\LabTech\Installer\Agent_Install.msi")) {
                        #Run MSI uninstaller for current installation
                        Write-Verbose "Launching MSI Uninstall."
                        Write-Debug "Line $(LINENUM): Executing Command ""msiexec.exe $($xarg)"""
                        Start-Process -Wait -FilePath "$env:windir\system32\msiexec.exe" -ArgumentList $xarg -WorkingDirectory $env:TEMP
                        Start-Sleep -Seconds 5
                    } Else {
                        Write-Verbose "WARNING: $($env:windir)\temp\LabTech\Installer\Agent_Install.msi was not found."
                    }
                }
                If ($PSCmdlet.ShouldProcess("$($env:windir)\temp\Agent_Uninstall.exe", "Execute Agent Uninstall")) {
                    If ((Test-Path "$($env:windir)\temp\Agent_Uninstall.exe")) {
                        #Run Agent_Uninstall.exe
                        Write-Verbose "Launching Agent Uninstaller"
                        Write-Debug "Line $(LINENUM): Executing Command ""$($env:windir)\temp\Agent_Uninstall.exe"""
                        Start-Process -Wait -FilePath "$($env:windir)\temp\Agent_Uninstall.exe" -WorkingDirectory $env:TEMP
                        Start-Sleep -Seconds 5
                    } Else {
                        Write-Verbose "WARNING: $($env:windir)\temp\Agent_Uninstall.exe was not found."
                    }
                }
                Write-Verbose "Removing Services if found."
                #Remove Services
                @('LTService','LTSvcMon','LabVNC') | ForEach-Object {
                    If (Get-Service $_ -EA 0) {
                        If ( $PSCmdlet.ShouldProcess("$($_)","Remove Service") ) {
                            Write-Debug "Line $(LINENUM): Removing Service: $($_)"
                            Try {& "$env:windir\system32\sc.exe" delete "$($_)" 2>''}
                            Catch {Write-Output "Error calling sc.exe."}
                        }
                    }
                }
                Write-Verbose "Cleaning Files remaining if found."
                #Remove %ltsvcdir% - Depth First Removal, First by purging files, then Removing Folders, to get as much removed as possible if complete removal fails
                @($BasePath, "$($env:windir)\temp\_ltupdate", "$($env:windir)\temp\_ltupdate") | foreach-object {
                    If ((Test-Path "$($_)" -EA 0)) {
                        If ( $PSCmdlet.ShouldProcess("$($_)","Remove Folder") ) {
                            Write-Debug "Line $(LINENUM): Removing Folder: $($_)"
                            Try {
                                Get-ChildItem -Path $_ -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { ($_.psiscontainer) } | foreach-object { Get-ChildItem -Path "$($_.FullName)" -EA 0 | Where-Object { -not ($_.psiscontainer) } | Remove-Item -Force -ErrorAction SilentlyContinue -Confirm:$False -WhatIf:$False }
                                Get-ChildItem -Path $_ -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { ($_.psiscontainer) } | Sort-Object { $_.fullname.length } -Descending | Remove-Item -Force -ErrorAction SilentlyContinue -Recurse -Confirm:$False -WhatIf:$False
                                Remove-Item -Recurse -Force -Path $_ -ErrorAction SilentlyContinue -Confirm:$False -WhatIf:$False
                            } Catch {}
                        }
                    }
                }
                Write-Verbose "Cleaning Registry Keys if found."
                #Remove all registry keys - Depth First Value Removal, then Key Removal, to get as much removed as possible if complete removal fails
                Foreach ($reg in $regs) {
                    If ((Test-Path "$($reg)" -EA 0)) {
                        Write-Debug "Line $(LINENUM): Found Registry Key: $($reg)"
                        If ( $PSCmdlet.ShouldProcess("$($Reg)","Remove Registry Key") ) {
                            Try {
                                Get-ChildItem -Path $reg -Recurse -Force -ErrorAction SilentlyContinue | Sort-Object { $_.name.length } -Descending | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue -Confirm:$False -WhatIf:$False
                                Remove-Item -Recurse -Force -Path $reg -ErrorAction SilentlyContinue -Confirm:$False -WhatIf:$False
                            } Catch {}
                        }
                    }
                }
            }
            Catch{
                Write-Error "ERROR: Line $(LINENUM): There was an error during the uninstall process. $($Error[0])" -ErrorAction Stop
            }
            If ($WhatIfPreference -ne $True) {
                If ($?){
                    #Post Uninstall Check
                    If((Test-Path "$env:windir\ltsvc") -or (Test-Path "$env:windir\temp\_ltupdate") -or (Test-Path registry::HKLM\Software\LabTech\Service) -or (Test-Path registry::HKLM\Software\WOW6432Node\Labtech\Service)){
                        Start-Sleep -Seconds 10
                    }
                    If((Test-Path "$env:windir\ltsvc") -or (Test-Path "$env:windir\temp\_ltupdate") -or (Test-Path registry::HKLM\Software\LabTech\Service) -or (Test-Path registry::HKLM\Software\WOW6432Node\Labtech\Service)){
                        Write-Error "ERROR: Line $(LINENUM): Remnants of previous install still detected after uninstall attempt. Please reboot and try again."
                    } Else {
                        Write-Output "LabTech has been successfully uninstalled."
                    }
                } Else {
                    $($Error[0])
                }
            }
        } ElseIf ($WhatIfPreference -ne $True) {
            Write-Error "ERROR: Line $(LINENUM): No valid server was reached to use for the uninstall." -ErrorAction Stop
        }
        Write-Debug "Exiting $($myInvocation.InvocationName) at line $(LINENUM)"
    }
}
Function Update-CWAA{
    [CmdletBinding(SupportsShouldProcess=$True)]
    [Alias('Update-LTService')]
    Param(
        [parameter(Position=0)]
        [AllowNull()]
        [string]$Version
    )
    Begin{
        Write-Debug "Starting $($myInvocation.InvocationName) at line $(LINENUM)"
        Clear-Variable Svr, GoodServer, Settings -EA 0 -WhatIf:$False -Confirm:$False #Clearing Variables for use
        $Settings = Get-CWAAInfo -EA 0 -Verbose:$False -WhatIf:$False -Confirm:$False
        $updaterPath = [System.Environment]::ExpandEnvironmentVariables("%windir%\temp\_LTUpdate")
        $xarg=@("/o""$updaterPath""","/y")
        $uarg=@("""$updaterPath\Update.ini""")
    }
    Process{
        if (-not ($Server)){
            If ($Settings){
                $Server = $Settings|Select-Object -Expand 'Server' -EA 0
            }
        }
        $Server=ForEach ($Svr in $Server) {If ($Svr -notmatch 'https?://.+') {"https://$($Svr)"}; $Svr}
        Foreach ($Svr in $Server) {
            If (-not ($GoodServer)) {
                If ($Svr -match '^(https?://)?(([12]?[0-9]{1,2}\.){3}[12]?[0-9]{1,2}|[a-z0-9][a-z0-9_-]*(\.[a-z0-9][a-z0-9_-]*)*)$') {
                    If ($Svr -notmatch 'https?://.+') {$Svr = "http://$($Svr)"}
                    Try {
                        $SvrVerCheck = "$($Svr)/Labtech/Agent.aspx"
                        Write-Debug "Line $(LINENUM): Testing Server Response and Version: $SvrVerCheck"
                        $SvrVer = $Script:LTServiceNetWebClient.DownloadString($SvrVerCheck)
                        Write-Debug "Line $(LINENUM): Raw Response: $SvrVer"
                        $SVer = $SvrVer|select-string -pattern '(?<=[|]{6})[0-9]{1,3}\.[0-9]{1,3}'|ForEach-Object {$_.matches}|Select-Object -Expand value -EA 0
                        If ($Null -eq ($SVer)) {
                            Write-Verbose "Unable to test version response from $($Svr)."
                            Continue
                        }
                        If ($Version -match '[1-9][0-9]{2}\.[0-9]{1,3}') {
                            $updater = "$($Svr)/Labtech/Updates/LabtechUpdate_$($Version).zip"
                        } ElseIf ([System.Version]$SVer -ge [System.Version]'105.001') {
                            $Version = $SVer
                            Write-Verbose "Using detected version ($Version) from server: $($Svr)."
                            $updater = "$($Svr)/Labtech/Updates/LabtechUpdate_$($Version).zip"
                        }
                        #Kill all running processes from $updaterPath
                        if (Test-Path $updaterPath){
                            $Executables = (Get-ChildItem $updaterPath -Filter *.exe -Recurse -ErrorAction SilentlyContinue|Select-Object -Expand FullName)
                            if ($Executables) {
                                Write-Verbose "Terminating LabTech Processes from $($updaterPath) if found running: $(($Executables) -replace [Regex]::Escape($updaterPath),'' -replace '^\\','')"
                                Get-Process | Where-Object {$Executables -contains $_.Path } | ForEach-Object {
                                    Write-Debug "Line $(LINENUM): Terminating Process $($_.ProcessName)"
                                    $($_) | Stop-Process -Force -ErrorAction SilentlyContinue
                                }
                            }
                        }
                        #Remove $updaterPath - Depth First Removal, First by purging files, then Removing Folders, to get as much removed as possible if complete removal fails
                        @("$updaterPath") | foreach-object {
                            If ((Test-Path "$($_)" -EA 0)) {
                                If ( $PSCmdlet.ShouldProcess("$($_)","Remove Folder") ) {
                                    Write-Debug "Line $(LINENUM): Removing Folder: $($_)"
                                    Try {
                                        Get-ChildItem -Path $_ -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { ($_.psiscontainer) } | foreach-object { Get-ChildItem -Path "$($_.FullName)" -EA 0 | Where-Object { -not ($_.psiscontainer) } | Remove-Item -Force -ErrorAction SilentlyContinue -Confirm:$False -WhatIf:$False }
                                        Get-ChildItem -Path $_ -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { ($_.psiscontainer) } | Sort-Object { $_.fullname.length } -Descending | Remove-Item -Force -ErrorAction SilentlyContinue -Recurse -Confirm:$False -WhatIf:$False
                                        Remove-Item -Recurse -Force -Path $_ -ErrorAction SilentlyContinue -Confirm:$False -WhatIf:$False
                                    } Catch {}
                                }
                            }
                        }
                        Try {
                            If (-not (Test-Path -PathType Container -Path "$updaterPath" )){
                                New-Item "$updaterPath" -type directory -ErrorAction SilentlyContinue | Out-Null
                            }
                            $updaterTest = [System.Net.WebRequest]::Create($updater)
                            If (($Script:LTProxy.Enabled) -eq $True) {
                                Write-Debug "Line $(LINENUM): Proxy Configuration Needed. Applying Proxy Settings to request."
                                $updaterTest.Proxy=$Script:LTWebProxy
                            }
                            $updaterTest.KeepAlive=$False
                            $updaterTest.ProtocolVersion = '1.0'
                            $updaterResult = $updaterTest.GetResponse()
                            $updaterTest.Abort()
                            If ($updaterResult.StatusCode -ne 200) {
                                Write-Warning "WARNING: Line $(LINENUM): Unable to download LabtechUpdate.exe version $Version from server $($Svr)."
                                Continue
                            } Else {
                                If ( $PSCmdlet.ShouldProcess($updater, "DownloadFile") ) {
                                    Write-Debug "Line $(LINENUM): Downloading LabtechUpdate.exe from $updater"
                                    $Script:LTServiceNetWebClient.DownloadFile($updater,"$updaterPath\LabtechUpdate.exe")
                                    If((Test-Path "$updaterPath\LabtechUpdate.exe") -and  !((Get-Item "$updaterPath\LabtechUpdate.exe" -EA 0).length/1KB -gt 1234)) {
                                        Write-Warning "WARNING: Line $(LINENUM): LabtechUpdate.exe size is below normal. Removing suspected corrupt file."
                                        Remove-Item "$updaterPath\LabtechUpdate.exe" -ErrorAction SilentlyContinue -Force -Confirm:$False
                                        Continue
                                    }
                                }
                                If ($WhatIfPreference -eq $True) {
                                    $GoodServer = $Svr
                                } ElseIf (Test-Path "$updaterPath\LabtechUpdate.exe") {
                                    $GoodServer = $Svr
                                    Write-Verbose "LabtechUpdate.exe downloaded successfully from server $($Svr)."
                                } Else {
                                    Write-Warning "WARNING: Line $(LINENUM): Error encountered downloading from $($Svr). No update file was received."
                                    Continue
                                }
                            }
                        }
                        Catch {
                            Write-Warning "WARNING: Line $(LINENUM): Error encountered downloading $updater."
                            Continue
                        }
                    }
                    Catch {
                        Write-Warning "WARNING: Line $(LINENUM): Error encountered downloading from $($Svr)."
                        Continue
                    }
                } Else {
                    Write-Warning "WARNING: Line $(LINENUM): Server address $($Svr) is not formatted correctly. Example: https://lt.domain.com"
                }
            } Else {
                Write-Debug "Line $(LINENUM): Server $($GoodServer) has been selected."
                Write-Verbose "Server has already been selected - Skipping $($Svr)."
            }
        }
    }
    End{
        $detectedVersion = $Settings|Select-Object -Expand 'Version' -EA 0
        If ($Null -eq $detectedVersion){
            Write-Error "ERROR: Line $(LINENUM): No existing installation was found." -ErrorAction Stop
            Return
        }
        If ([System.Version]$detectedVersion -ge [System.Version]$Version) {
            Write-Warning "WARNING: Line $(LINENUM): Installed version detected ($detectedVersion) is higher than or equal to the requested version ($Version)."
            Return
        }
        If (-not ($GoodServer)) {
            Write-Warning "WARNING: Line $(LINENUM): No valid server was detected."
            Return
        }
        If ([System.Version]$SVer -gt [System.Version]$Version) {
            Write-Warning "WARNING: Line $(LINENUM): Server version detected ($SVer) is higher than the requested version ($Version)."
            Return
        }
        Try{
            Stop-CWAA
        }
        Catch{
            Write-Error "ERROR: Line $(LINENUM): There was an error stopping the services. $($Error[0])"
            Return
        }
        Write-Output "Updating Agent with the following information: Server $($GoodServer), Version $Version"
        Try{
            If ($PSCmdlet.ShouldProcess("LabtechUpdate.exe $($xarg)", "Extracting update files")) {
                If ((Test-Path "$updaterPath\LabtechUpdate.exe")) {
                    #Extract Update Files
                    Write-Verbose "Launching LabtechUpdate Self-Extractor."
                    Write-Debug "Line $(LINENUM): Executing Command ""LabtechUpdate.exe $($xarg)"""
                    Try {
                        Push-Location $updaterPath
                        & "$updaterPath\LabtechUpdate.exe" $($xarg) 2>''
                        Pop-Location
                    }
                    Catch {Write-Output "Error calling LabtechUpdate.exe."}
                    Start-Sleep -Seconds 5
                } Else {
                    Write-Verbose "WARNING: $updaterPath\LabtechUpdate.exe was not found."
                }
            }
            If ($PSCmdlet.ShouldProcess("Update.exe $($uarg)", "Launching Updater")) {
                If ((Test-Path "$updaterPath\Update.exe")) {
                    #Extract Update Files
                    Write-Verbose "Launching Labtech Updater"
                    Write-Debug "Line $(LINENUM): Executing Command ""Update.exe $($uarg)"""
                    Try {& "$updaterPath\Update.exe" $($uarg) 2>''}
                    Catch {Write-Output "Error calling Update.exe."}
                    Start-Sleep -Seconds 5
                } Else {
                    Write-Verbose "WARNING: $updaterPath\Update.exe was not found."
                }
            }
        }
        Catch{
            Write-Error "ERROR: Line $(LINENUM): There was an error during the update process $($Error[0])" -ErrorAction Continue
        }
        Try{
            Start-CWAA
        }
        Catch{
            Write-Error "ERROR: Line $(LINENUM): There was an error starting the services. $($Error[0])"
            Return
        }
        If ($WhatIfPreference -ne $True) {
            If ($?) {}
            Else {$Error[0]}
        }
        Write-Debug "Exiting $($myInvocation.InvocationName) at line $(LINENUM)"
    }
}
Function Get-CWAAError {
    [CmdletBinding()]
    [Alias('Get-LTErrors')]
    Param()
    Begin{
        Write-Debug "Starting $($myInvocation.InvocationName) at line $(LINENUM)"
        $BasePath = $(Get-CWAAInfo -EA 0 -Verbose:$False -WhatIf:$False -Confirm:$False -Debug:$False|Select-Object -Expand BasePath -EA 0)
        if (!$BasePath){$BasePath = "$env:windir\LTSVC"}
    }
    Process{
        if ($(Test-Path -Path "$BasePath\LTErrors.txt") -eq $False) {
            Write-Error "ERROR: Line $(LINENUM): Unable to find lelog."
            return
        }
        Try{
            $errors = Get-Content "$BasePath\LTErrors.txt"
            $errors = $errors -join ' ' -split '::: '
            foreach($Line in $Errors){
                $items = $Line -split "`t" -replace ' - ',''
                if ($items[1]){
                    $object = New-Object -TypeName PSObject
                    $object | Add-Member -MemberType NoteProperty -Name ServiceVersion -Value $items[0]
                    $object | Add-Member -MemberType NoteProperty -Name Timestamp -Value $(Try {[datetime]::Parse($items[1])} Catch {})
                    $object | Add-Member -MemberType NoteProperty -Name Message -Value $items[2]
                    Write-Output $object
                }
            }
        }
        Catch{
            Write-Error "ERROR: Line $(LINENUM): There was an error reading the log. $($Error[0])"
        }
    }
    End{
        if ($?){
        }
        Else {$Error[0]}
        Write-Debug "Exiting $($myInvocation.InvocationName) at line $(LINENUM)"
    }
}
Function Get-CWAALogLevel{
    [CmdletBinding()]
    [Alias('Get-LTLogging')]
    Param ()
    Begin{
        Write-Verbose "Checking for registry keys."
    }
    Process{
        Try{
            $Value = (Get-CWAASettings|Select-Object -Expand Debuging -EA 0)
        }
        Catch{
            Write-Error "ERROR: Line $(LINENUM): There was a problem reading the registry key. $($Error[0])"
            return
        }
    }
    End{
        if ($?){
            if ($value -eq 1){
                Write-Output "Current logging level: Normal"
            }
            elseif ($value -eq 1000){
                Write-Output "Current logging level: Verbose"
            }
            else{
                Write-Error "ERROR: Line $(LINENUM): Unknown Logging level $($value)"
            }
        }
    }
}
Function Get-CWAAProbeError {
    [CmdletBinding()]
    [Alias('Get-LTProbeErrors')]
    Param()
    Begin{
        Write-Debug "Starting $($myInvocation.InvocationName) at line $(LINENUM)"
        $BasePath = $(Get-CWAAInfo -EA 0 -Verbose:$False -WhatIf:$False -Confirm:$False -Debug:$False|Select-Object -Expand BasePath -EA 0)
        if (!($BasePath)){$BasePath = "$env:windir\LTSVC"}
    }
    Process{
        if ($(Test-Path -Path "$BasePath\LTProbeErrors.txt") -eq $False) {
            Write-Error "ERROR: Line $(LINENUM): Unable to find log."
            return
        }
        $errors = Get-Content "$BasePath\LTProbeErrors.txt"
        $errors = $errors -join ' ' -split '::: '
        Try {
            Foreach($Line in $Errors){
                $items = $Line -split "`t" -replace ' - ',''
                $object = New-Object -TypeName PSObject
                $object | Add-Member -MemberType NoteProperty -Name ServiceVersion -Value $items[0]
                $object | Add-Member -MemberType NoteProperty -Name Timestamp -Value $(Try {[datetime]::Parse($items[1])} Catch {})
                $object | Add-Member -MemberType NoteProperty -Name Message -Value $items[2]
                Write-Output $object
            }
        }
        Catch{
            Write-Error "ERROR: Line $(LINENUM): There was an error reading the log. $($Error[0])"
        }
    }
    End{
        if ($?){
        }
        Else {$Error[0]}
        Write-Debug "Exiting $($myInvocation.InvocationName) at line $(LINENUM)"
    }
}
Function Set-CWAALogLevel {
    [CmdletBinding()]
    [Alias('Set-LTLogging')]
    Param (
        [ValidateSet('Normal', 'Verbose')]
        $Level = 'Normal'
    )
    Begin{}
    Process{
        Try{
            Stop-CWAA
            if ($Level -eq 'Normal'){
                Set-ItemProperty HKLM:\SOFTWARE\LabTech\Service\Settings -Name 'Debuging' -Value 1
            }
            if ($Level -eq 'Verbose'){
                Set-ItemProperty HKLM:\SOFTWARE\LabTech\Service\Settings -Name 'Debuging' -Value 1000
            }
            Start-CWAA
        }
        Catch{
            Write-Error "ERROR: Line $(LINENUM): There was a problem writing the registry key. $($Error[0])" -ErrorAction Stop
        }
        }
        End{
        if ($?){
            Get-CWAALogging
        }
    }
}
Function Get-CWAAProxy{
    [CmdletBinding()]
    [Alias('Get-LTProxy')]
    Param(
    )
    Begin{
        Clear-Variable CustomProxyObject,LTSI,LTSS -EA 0 -WhatIf:$False -Confirm:$False #Clearing Variables for use
        Write-Debug "Starting $($myInvocation.InvocationName) at line $(LINENUM)"
        Write-Verbose "Discovering Proxy Settings used by the LT Agent."
        $Null=Initialize-CWAAKeys
    }
    Process{
        Try {
            $LTSI=Get-CWAAInfo -EA 0 -WA 0 -Verbose:$False -WhatIf:$False -Confirm:$False -Debug:$False
            If ($Null -ne $LTSI -and ($LTSI|Get-Member|Where-Object {$_.Name -eq 'ServerPassword'})) {
                $LTSS=Get-CWAASettings -EA 0 -Verbose:$False -WA 0 -Debug:$False
                If ($Null -ne $LTSS) {
                    If (($LTSS|Get-Member|Where-Object {$_.Name -eq 'ProxyServerURL'}) -and ($($LTSS|Select-Object -Expand ProxyServerURL -EA 0) -Match 'https?://.+')) {
                        Write-Debug "Line $(LINENUM): Proxy Detected. Setting ProxyServerURL to $($LTSS|Select-Object -Expand ProxyServerURL -EA 0)"
                        $Script:LTProxy.Enabled=$True
                        $Script:LTProxy.ProxyServerURL="$($LTSS|Select-Object -Expand ProxyServerURL -EA 0)"
                    } Else {
                        Write-Debug "Line $(LINENUM): Setting ProxyServerURL to "
                        $Script:LTProxy.Enabled=$False
                        $Script:LTProxy.ProxyServerURL=''
                    }
                    if ($Script:LTProxy.Enabled -eq $True -and ($LTSS|Get-Member|Where-Object {$_.Name -eq 'ProxyUsername'}) -and ($LTSS|Select-Object -Expand ProxyUsername -EA 0)) {
                        $Script:LTProxy.ProxyUsername="$(ConvertFrom-CWAASecurity -InputString "$($LTSS|Select-Object -Expand ProxyUsername -EA 0)" -Key ("$($Script:LTServiceKeys.PasswordString)",''))"
                        Write-Debug "Line $(LINENUM): Setting ProxyUsername to $($Script:LTProxy.ProxyUsername)"
                    } Else {
                        Write-Debug "Line $(LINENUM): Setting ProxyUsername to "
                        $Script:LTProxy.ProxyUsername=''
                    }
                    If ($Script:LTProxy.Enabled -eq $True -and ($LTSS|Get-Member|Where-Object {$_.Name -eq 'ProxyPassword'}) -and ($LTSS|Select-Object -Expand ProxyPassword -EA 0)) {
                        $Script:LTProxy.ProxyPassword="$(ConvertFrom-CWAASecurity -InputString "$($LTSS|Select-Object -Expand ProxyPassword -EA 0)" -Key ("$($Script:LTServiceKeys.PasswordString)",''))"
                        Write-Debug "Line $(LINENUM): Setting ProxyPassword to $($Script:LTProxy.ProxyPassword)"
                    } Else {
                        Write-Debug "Line $(LINENUM): Setting ProxyPassword to "
                        $Script:LTProxy.ProxyPassword=''
                    }
                }
            } Else {
                Write-Verbose "No Server password or settings exist. No Proxy information will be available."
            }
        }
        Catch{
            Write-Error "ERROR: Line $(LINENUM): There was a problem retrieving Proxy Information. $($Error[0])"
        }
    }
    End{
        Write-Debug "Exiting $($myInvocation.InvocationName) at line $(LINENUM)"
        return $Script:LTProxy
    }
}
Function Set-CWAAProxy{
    [CmdletBinding(SupportsShouldProcess=$True)]
    [Alias('Set-LTProxy')]
    Param(
        [parameter(Mandatory = $False, ValueFromPipeline = $True, ValueFromPipelineByPropertyName = $True, Position = 0)]
        [string]$ProxyServerURL,
        [parameter(Mandatory = $False, ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $True, Position = 1)]
        [string]$ProxyUsername,
        [parameter(Mandatory = $False, ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $True, Position = 2)]
        [SecureString]$ProxyPassword,
        [parameter(Mandatory = $False, ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $True)]
        [string]$EncodedProxyUsername,
        [parameter(Mandatory = $False, ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $True)]
        [SecureString]$EncodedProxyPassword,
        [parameter(Mandatory = $False, ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $True)]
        [alias('Detect')]
        [alias('AutoDetect')]
        [switch]$DetectProxy,
        [parameter(Mandatory = $False, ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $True)]
        [alias('Clear')]
        [alias('Reset')]
        [alias('ClearProxy')]
        [switch]$ResetProxy
    )
    Begin {
        Clear-Variable LTServiceSettingsChanged,LTSS,LTServiceRestartNeeded,proxyURL,proxyUser,proxyPass,passwd,Svr -EA 0 -WhatIf:$False -Confirm:$False #Clearing Variables for use
        Write-Debug "Starting $($myInvocation.InvocationName) at line $(LINENUM)"
        try {
            $LTSS=Get-CWAASettings -EA 0 -Verbose:$False -WA 0 -Debug:$False
        } catch {}
    }
    Process{
        If (
(($ResetProxy -eq $True) -and (($DetectProxy -eq $True) -or ($ProxyServerURL) -or ($ProxyUsername) -or ($ProxyPassword) -or ($EncodedProxyUsername) -or ($EncodedProxyPassword))) -or
(($DetectProxy -eq $True) -and (($ResetProxy -eq $True) -or ($ProxyServerURL) -or ($ProxyUsername) -or ($ProxyPassword) -or ($EncodedProxyUsername) -or ($EncodedProxyPassword))) -or
((($ProxyServerURL) -or ($ProxyUsername) -or ($ProxyPassword) -or ($EncodedProxyUsername) -or ($EncodedProxyPassword)) -and (($ResetProxy -eq $True) -or ($DetectProxy -eq $True))) -or
((($ProxyUsername) -or ($ProxyPassword)) -and (-not ($ProxyServerURL) -or ($EncodedProxyUsername) -or ($EncodedProxyPassword) -or ($ResetProxy -eq $True) -or ($DetectProxy -eq $True))) -or
((($EncodedProxyUsername) -or ($EncodedProxyPassword)) -and (-not ($ProxyServerURL) -or ($ProxyUsername) -or ($ProxyPassword) -or ($ResetProxy -eq $True) -or ($DetectProxy -eq $True)))
        ) {Write-Error "ERROR: Line $(LINENUM): Set-CWAAProxy: Invalid Parameter specified" -ErrorAction Stop}
        If (-not (($ResetProxy -eq $True) -or ($DetectProxy -eq $True) -or ($ProxyServerURL) -or ($ProxyUsername) -or ($ProxyPassword) -or ($EncodedProxyUsername) -or ($EncodedProxyPassword)))
        {
            If ($Args.Count -gt 0) {Write-Error "ERROR: Line $(LINENUM): Set-CWAAProxy: Unknown Parameter specified" -ErrorAction Stop}
            Else {Write-Error "ERROR: Line $(LINENUM): Set-CWAAProxy: Required Parameters Missing" -ErrorAction Stop}
        }
        Try{
            If ($($ResetProxy) -eq $True) {
                Write-Verbose "ResetProxy selected. Clearing Proxy Settings."
                If ( $PSCmdlet.ShouldProcess("LTProxy", "Clear") ) {
                    $Script:LTProxy.Enabled=$False
                    $Script:LTProxy.ProxyServerURL=''
                    $Script:LTProxy.ProxyUsername=''
                    $Script:LTProxy.ProxyPassword=''
                    $Script:LTWebProxy=New-Object System.Net.WebProxy
                    $Script:LTServiceNetWebClient.Proxy=$Script:LTWebProxy
                }
            } ElseIf ($($DetectProxy) -eq $True) {
                Write-Verbose "DetectProxy selected. Attempting to Detect Proxy Settings."
                If ( $PSCmdlet.ShouldProcess("LTProxy", "Detect") ) {
                    $Script:LTWebProxy=[System.Net.WebRequest]::GetSystemWebProxy()
                    $Script:LTProxy.Enabled=$False
                    $Script:LTProxy.ProxyServerURL=''
                    $Servers = @($("$($LTSS|Select-Object -Expand 'ServerAddress' -EA 0)|www.connectwise.com").Split('|')|ForEach-Object {$_.Trim()})
                    Foreach ($Svr In $Servers) {
                        If (-not ($Script:LTProxy.Enabled)) {
                            If ($Svr -match '^(https?://)?(([12]?[0-9]{1,2}\.){3}[12]?[0-9]{1,2}|[a-z0-9][a-z0-9_-]*(\.[a-z0-9][a-z0-9_-]*)*)$') {
                                $Svr = $Svr -replace 'https?://',''
                                Try{
                                    $Script:LTProxy.ProxyServerURL=$Script:LTWebProxy.GetProxy("http://$($Svr)").Authority
                                } catch {}
                                If (($Null -ne $Script:LTProxy.ProxyServerURL) -and ($Script:LTProxy.ProxyServerURL -ne '') -and ($Script:LTProxy.ProxyServerURL -notcontains "$($Svr)")) {
                                    Write-Debug "Line $(LINENUM): Detected Proxy URL: $($Script:LTProxy.ProxyServerURL) on server $($Svr)"
                                    $Script:LTProxy.Enabled=$True
                                }
                            }
                        }
                    }
                    If (-not ($Script:LTProxy.Enabled)) {
                        if (($Script:LTProxy.ProxyServerURL -eq '') -or ($Script:LTProxy.ProxyServerURL -contains '$Svr')) {
                            $Script:LTProxy.ProxyServerURL = netsh winhttp show proxy | select-string -pattern '(?i)(?<=Proxyserver.*http\=)([^;\r\n]*)' -EA 0|ForEach-Object {$_.matches}|Select-Object -Expand value
                        }
                        if (($Null -eq $Script:LTProxy.ProxyServerURL) -or ($Script:LTProxy.ProxyServerURL -eq '')) {
                            $Script:LTProxy.ProxyServerURL=''
                            $Script:LTProxy.Enabled=$False
                        } else {
                            $Script:LTProxy.Enabled=$True
                            Write-Debug "Line $(LINENUM): Detected Proxy URL: $($Script:LTProxy.ProxyServerURL)"
                        }
                    }
                    $Script:LTProxy.ProxyUsername=''
                    $Script:LTProxy.ProxyPassword=''
                    $Script:LTServiceNetWebClient.Proxy=$Script:LTWebProxy
                }
            } ElseIf (($ProxyServerURL)) {
                If ( $PSCmdlet.ShouldProcess("LTProxy", "Set") ) {
                    foreach ($ProxyURL in $ProxyServerURL) {
                        $Script:LTWebProxy = New-Object System.Net.WebProxy($ProxyURL, $true);
                        $Script:LTProxy.Enabled=$True
                        $Script:LTProxy.ProxyServerURL=$ProxyURL
                    }
                    Write-Verbose "Setting Proxy URL to: $($ProxyServerURL)"
                    If ((($ProxyUsername) -and ($ProxyPassword)) -or (($EncodedProxyUsername) -and ($EncodedProxyPassword))) {
                        If (($ProxyUsername)) {
                            foreach ($proxyUser in $ProxyUsername) {
                                $Script:LTProxy.ProxyUsername=$proxyUser
                            }
                        }
                        If (($EncodedProxyUsername)) {
                            foreach ($proxyUser in $EncodedProxyUsername) {
                                $Script:LTProxy.ProxyUsername=$(ConvertFrom-CWAASecurity -InputString "$($proxyUser)" -Key ("$($Script:LTServiceKeys.PasswordString)",''))
                            }
                        }
                        If (($ProxyPassword)) {
                            foreach ($proxyPass in $ProxyPassword) {
                                $Script:LTProxy.ProxyPassword=$proxyPass
                                $passwd = ConvertTo-SecureString $proxyPass -AsPlainText -Force; ## Website credentials
                            }
                        }
                        If (($EncodedProxyPassword)) {
                            foreach ($proxyPass in $EncodedProxyPassword) {
                                $Script:LTProxy.ProxyPassword=$(ConvertFrom-CWAASecurity -InputString "$($proxyPass)" -Key ("$($Script:LTServiceKeys.PasswordString)",''))
                                $passwd = ConvertTo-SecureString $Script:LTProxy.ProxyPassword -AsPlainText -Force; ## Website credentials
                            }
                        }
                        $Script:LTWebProxy.Credentials = New-Object System.Management.Automation.PSCredential ($Script:LTProxy.ProxyUsername, $passwd);
                    }
                    $Script:LTServiceNetWebClient.Proxy=$Script:LTWebProxy
                }
            }
        }
        Catch{
            Write-Error "ERROR: Line $(LINENUM): There was an error during the Proxy Configuration process. $($Error[0])" -ErrorAction Stop
        }
    }
    End{
        If ($?){
            $LTServiceSettingsChanged=$False
            If ($Null -ne ($LTSS)) {
                If (($LTSS|Get-Member|Where-Object {$_.Name -eq 'ProxyServerURL'})) {
                    If (($($LTSS|Select-Object -Expand ProxyServerURL -EA 0) -replace 'https?://','' -ne $Script:LTProxy.ProxyServerURL) -and (($($LTSS|Select-Object -Expand ProxyServerURL -EA 0) -replace 'https?://','' -eq '' -and $Script:LTProxy.Enabled -eq $True -and $Script:LTProxy.ProxyServerURL -match '.+\..+') -or ($($LTSS|Select-Object -Expand ProxyServerURL -EA 0) -replace 'https?://','' -ne '' -and ($Script:LTProxy.ProxyServerURL -ne '' -or $Script:LTProxy.Enabled -eq $False)))) {
                        Write-Debug "Line $(LINENUM): ProxyServerURL Changed: Old Value: $($LTSS|Select-Object -Expand ProxyServerURL -EA 0) New Value: $($Script:LTProxy.ProxyServerURL)"
                        $LTServiceSettingsChanged=$True
                    }
                    If (($LTSS|Get-Member|Where-Object {$_.Name -eq 'ProxyUsername'}) -and ($LTSS|Select-Object -Expand ProxyUsername -EA 0)) {
                        If ($(ConvertFrom-CWAASecurity -InputString "$($LTSS|Select-Object -Expand ProxyUsername -EA 0)" -Key ("$($Script:LTServiceKeys.PasswordString)",'')) -ne $Script:LTProxy.ProxyUsername) {
                            Write-Debug "Line $(LINENUM): ProxyUsername Changed: Old Value: $(ConvertFrom-CWAASecurity -InputString "$($LTSS|Select-Object -Expand ProxyUsername -EA 0)" -Key ("$($Script:LTServiceKeys.PasswordString)",'')) New Value: $($Script:LTProxy.ProxyUsername)"
                            $LTServiceSettingsChanged=$True
                        }
                    }
                    If ($Null -ne ($LTSS) -and ($LTSS|Get-Member|Where-Object {$_.Name -eq 'ProxyPassword'}) -and ($LTSS|Select-Object -Expand ProxyPassword -EA 0)) {
                        If ($(ConvertFrom-CWAASecurity -InputString "$($LTSS|Select-Object -Expand ProxyPassword -EA 0)" -Key ("$($Script:LTServiceKeys.PasswordString)",'')) -ne $Script:LTProxy.ProxyPassword) {
                            Write-Debug "Line $(LINENUM): ProxyPassword Changed: Old Value: $(ConvertFrom-CWAASecurity -InputString "$($LTSS|Select-Object -Expand ProxyPassword -EA 0)" -Key ("$($Script:LTServiceKeys.PasswordString)",'')) New Value: $($Script:LTProxy.ProxyPassword)"
                            $LTServiceSettingsChanged=$True
                        }
                    }
                } ElseIf ($Script:LTProxy.Enabled -eq $True -and $Script:LTProxy.ProxyServerURL -match '(https?://)?.+\..+') {
                    Write-Debug "Line $(LINENUM): ProxyServerURL Changed: Old Value: NOT SET New Value: $($Script:LTProxy.ProxyServerURL)"
                    $LTServiceSettingsChanged=$True
                }
            } Else {
                $svcRun = ('LTService') | Get-Service -EA 0 | Where-Object {$_.Status -eq 'Running'} | Measure-Object | Select-Object -Expand Count
                if (($svcRun -gt 0) -and ($($Script:LTProxy.ProxyServerURL) -match '.+')) {
                    $LTServiceSettingsChanged=$True
                }
            }
            If ($LTServiceSettingsChanged -eq $True) {
                If ((Get-Service 'LTService','LTSvcMon' -ErrorAction SilentlyContinue|Where-Object {$_.Status -match 'Running'})) { $LTServiceRestartNeeded=$True; try {Stop-CWAA -EA 0 -WA 0} catch {} }
                Write-Verbose "Updating LabTech\Service\Settings Proxy Configuration."
                If ( $PSCmdlet.ShouldProcess("LTService Registry", "Update") ) {
                    $Svr=$($Script:LTProxy.ProxyServerURL); If (($Svr -ne '') -and ($Svr -notmatch 'https?://')) {$Svr = "http://$($Svr)"}
                    @{"ProxyServerURL"=$Svr;
                    "ProxyUserName"="$(ConvertTo-CWAASecurity -InputString "$($Script:LTProxy.ProxyUserName)" -Key "$($Script:LTServiceKeys.PasswordString)")";
                    "ProxyPassword"="$(ConvertTo-CWAASecurity -InputString "$($Script:LTProxy.ProxyPassword)" -Key "$($Script:LTServiceKeys.PasswordString)")"}.GetEnumerator() | Foreach-Object {
                        Write-Debug "Line $(LINENUM): Setting Registry value for $($_.Name) to `"$($_.Value)`""
                        Set-ItemProperty -Path 'HKLM:Software\LabTech\Service\Settings' -Name $($_.Name) -Value $($_.Value) -EA 0 -Confirm:$False
                    }
                }
                If ($LTServiceRestartNeeded -eq $True) { try {Start-CWAA -EA 0 -WA 0} catch {} }
            }
        }
        Else {$Error[0]}
        Write-Debug "Exiting $($myInvocation.InvocationName) at line $(LINENUM)"
    }
}
Function Restart-CWAA {
    [CmdletBinding(SupportsShouldProcess=$True)]
    [Alias('Restart-LTService')]
    Param()
    Begin{
        Write-Debug "Starting $($myInvocation.InvocationName) at line $(LINENUM)"
    }
    Process{
        if (-not (Get-Service 'LTService','LTSvcMon' -ErrorAction SilentlyContinue)) {
            If ($WhatIfPreference -ne $True) {
                Write-Error "ERROR: Line $(LINENUM): Services NOT Found $($Error[0])"
                return
            } Else {
                Write-Error "What-If: Line $(LINENUM): Stopping: Services NOT Found"
                return
            }
        }
        Try{
            Stop-CWAA
        }
        Catch{
            Write-Error "ERROR: Line $(LINENUM): There was an error stopping the services. $($Error[0])"
            return
        }
        Try{
            Start-CWAA
        }
        Catch{
            Write-Error "ERROR: Line $(LINENUM): There was an error starting the services. $($Error[0])"
            return
        }
    }
    End{
        If ($WhatIfPreference -ne $True) {
            If ($?) {Write-Output "Services Restarted successfully."}
            Else {$Error[0]}
        }
        Write-Debug "Exiting $($myInvocation.InvocationName) at line $(LINENUM)"
    }
}
Function Start-CWAA {
    [CmdletBinding(SupportsShouldProcess=$True)]
    [Alias('Start-LTService')]
    Param()
    Begin{
        Write-Debug "Starting $($myInvocation.InvocationName) at line $(LINENUM)"
        #Identify processes that are using the tray port
        [array]$processes = @()
        $Port = (Get-CWAAInfo -EA 0 -Verbose:$False -WhatIf:$False -Confirm:$False -Debug:$False|Select-Object -Expand TrayPort -EA 0)
        if (-not ($Port)) {$Port = "42000"}
        $startedSvcCount=0
    }
    Process{
        If (-not (Get-Service 'LTService','LTSvcMon' -ErrorAction SilentlyContinue)) {
            If ($WhatIfPreference -ne $True) {
                Write-Error "ERROR: Line $(LINENUM): Services NOT Found $($Error[0])"
                return
            } Else {
                Write-Error "What If: Line $(LINENUM): Stopping: Services NOT Found"
                return
            }
        }
        Try{
            If((('LTService') | Get-Service -EA 0 | Where-Object {$_.Status -eq 'Stopped'} | Measure-Object | Select-Object -Expand Count) -gt 0) {
                Try {$netstat=& "$env:windir\system32\netstat.exe" -a -o -n 2>'' | Select-String -Pattern " .*[0-9\.]+:$($Port).*[0-9\.]+:[0-9]+ .*?([0-9]+)" -EA 0}
                Catch {Write-Output "Error calling netstat.exe."; $netstat=$null}
                Foreach ($line in $netstat){
                    $processes += ($line -split ' {4,}')[-1]
                }
                $processes = $processes | Where-Object {$_ -gt 0 -and $_ -match '^\d+$'}| Sort-Object | Get-Unique
                If ($processes) {
                    Foreach ($proc in $processes){
                        Write-Output "Process ID:$proc is using port $Port. Killing process."
                        Try{Stop-Process -ID $proc -Force -Verbose -EA Stop}
                        Catch {
                            Write-Warning "WARNING: Line $(LINENUM): There was an issue killing the following process: $proc"
                            Write-Warning "WARNING: Line $(LINENUM): This generally means that a 'protected application' is using this port."
                            $newPort = [int]$port + 1
                            if($newPort -gt 42009) {$newPort = 42000}
                            Write-Warning "WARNING: Line $(LINENUM): Setting tray port to $newPort."
                            New-ItemProperty -Path "HKLM:\Software\Labtech\Service" -Name TrayPort -PropertyType String -Value $newPort -Force -WhatIf:$False -Confirm:$False | Out-Null
                        }
                    }
                }
            }
            If ($PSCmdlet.ShouldProcess("LTService, LTSvcMon", "Start Service")) {
                @('LTService','LTSvcMon') | ForEach-Object {
                    If (Get-Service $_ -EA 0) {
                        Set-Service $_ -StartupType Automatic -EA 0 -Confirm:$False -WhatIf:$False
                        $Null=& "$env:windir\system32\sc.exe" start "$($_)" 2>''
                        $startedSvcCount++
                        Write-Debug "Line $(LINENUM): Executed Start Service for $($_)"
                    }
                }
            }
        }
        Catch{
            Write-Error "ERROR: Line $(LINENUM): There was an error starting the LabTech services. $($Error[0])"
            return
        }
    }
    End{
        If ($WhatIfPreference -ne $True) {
            If ($?){
                $svcnotRunning = ('LTService') | Get-Service -EA 0 | Where-Object {$_.Status -ne 'Running'} | Measure-Object | Select-Object -Expand Count
                If ($svcnotRunning -gt 0 -and $startedSvcCount -eq 2) {
                    $timeout = new-timespan -Minutes 1
                    $sw = [diagnostics.stopwatch]::StartNew()
                    Write-Host -NoNewline "Waiting for Services to Start."
                    Do {
                        Write-Host -NoNewline '.'
                        Start-Sleep 2
                        $svcnotRunning = ('LTService') | Get-Service -EA 0 | Where-Object {$_.Status -ne 'Running'} | Measure-Object | Select-Object -Expand Count
                    } Until ($sw.elapsed -gt $timeout -or $svcnotRunning -eq 0)
                    Write-Host ""
                    $sw.Stop()
                }
                If ($svcnotRunning -eq 0) {
                    Write-Output "Services Started successfully."
                    $Null=Invoke-CWAACommand 'Send Status' -EA 0 -Confirm:$False
                } ElseIf ($startedSvcCount -gt 0) {
                    Write-Output "Service Start was issued but LTService has not reached Running state."
                } Else {
                    Write-Output "Service Start was not issued."
                }
            }
            Else{
                $($Error[0])
            }
        }
        Write-Debug "Exiting $($myInvocation.InvocationName) at line $(LINENUM)"
    }
}
Function Stop-CWAA{
    [CmdletBinding(SupportsShouldProcess=$True)]
    [Alias('Stop-LTService')]
    Param()
    Begin{
        Clear-Variable sw,timeout,svcRun -EA 0 -WhatIf:$False -Confirm:$False -Verbose:$False #Clearing Variables for use
        Write-Debug "Starting $($myInvocation.InvocationName) at line $(LINENUM)"
    }
    Process{
        if (-not (Get-Service 'LTService','LTSvcMon' -ErrorAction SilentlyContinue)) {
            If ($WhatIfPreference -ne $True) {
                Write-Error "ERROR: Line $(LINENUM): Services NOT Found $($Error[0])"
                return
            } Else {
                Write-Error "What If: Line $(LINENUM): Stopping: Services NOT Found"
                return
            }
        }
        If ($PSCmdlet.ShouldProcess("LTService, LTSvcMon", "Stop-Service")) {
            $Null=Invoke-CWAACommand ('Kill VNC','Kill Trays') -EA 0 -WhatIf:$False -Confirm:$False
            Write-Verbose "Stopping Labtech Services"
            Try{
                ('LTService','LTSvcMon') | Foreach-Object {
                    Try {$Null=& "$env:windir\system32\sc.exe" stop "$($_)" 2>''}
                    Catch {Write-Output "Error calling sc.exe."}
                }
                $timeout = new-timespan -Minutes 1
                $sw = [diagnostics.stopwatch]::StartNew()
                Write-Host -NoNewline "Waiting for Services to Stop."
                Do {
                    Write-Host -NoNewline '.'
                    Start-Sleep 2
                    $svcRun = ('LTService','LTSvcMon') | Get-Service -EA 0 | Where-Object {$_.Status -ne 'Stopped'} | Measure-Object | Select-Object -Expand Count
                } Until ($sw.elapsed -gt $timeout -or $svcRun -eq 0)
                Write-Host ""
                $sw.Stop()
                if ($svcRun -gt 0) {
                    Write-Verbose "Services did not stop. Terminating Processes after $(([int32]$sw.Elapsed.TotalSeconds).ToString()) seconds."
                }
                Get-Process | Where-Object {@('LTTray','LTSVC','LTSvcMon') -contains $_.ProcessName } | Stop-Process -Force -ErrorAction Stop -Whatif:$False -Confirm:$False
            }
            Catch{
                Write-Error "ERROR: Line $(LINENUM): There was an error stopping the LabTech processes. $($Error[0])"
                return
            }
        }
    }
    End{
        If ($WhatIfPreference -ne $True) {
            If ($?) {
                If((('LTService','LTSvcMon') | Get-Service -EA 0 | Where-Object {$_.Status -ne 'Stopped'} | Measure-Object | Select-Object -Expand Count) -eq 0){
                    Write-Output "Services Stopped successfully."
                } Else {
                    Write-Warning "WARNING: Line $(LINENUM): Services have not stopped completely."
                }
            } Else {$Error[0]}
        }
        Write-Debug "Exiting $($myInvocation.InvocationName) at line $(LINENUM)"
    }
}
Function Get-CWAAInfo {
    [CmdletBinding(SupportsShouldProcess=$True, ConfirmImpact='Low')]
    [Alias('Get-LTServiceInfo')]
    Param ()
    Begin{
        Write-Debug "Starting $($myInvocation.InvocationName) at line $(LINENUM)"
        Clear-Variable key,BasePath,exclude,Servers -EA 0 -WhatIf:$False -Confirm:$False #Clearing Variables for use
        $exclude = "PSParentPath","PSChildName","PSDrive","PSProvider","PSPath"
        $key = $Null
    }
    Process{
        If ((Test-Path 'HKLM:\SOFTWARE\LabTech\Service') -eq $False){
            Write-Error "ERROR: Line $(LINENUM): Unable to find information on LTSvc. Make sure the agent is installed."
            Return $Null
        }
        If ($PSCmdlet.ShouldProcess("LTService", "Retrieving Service Registry Values")) {
            Write-Verbose "Checking for LT Service registry keys."
            Try{
                $key = Get-ItemProperty 'HKLM:\SOFTWARE\LabTech\Service' -ErrorAction Stop | Select-Object * -exclude $exclude
                If ($Null -ne $key -and -not ($key|Get-Member -EA 0|Where-Object {$_.Name -match 'BasePath'})) {
                    If ((Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LTService') -eq $True) {
                        Try {
                            $BasePath = Get-Item $( Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\LTService' -ErrorAction Stop|Select-Object -Expand ImagePath | Select-String -Pattern '^[^"][^ ]+|(?<=^")[^"]+'|Select-Object -Expand Matches -First 1 | Select-Object -Expand Value -EA 0 -First 1 ) | Select-Object -Expand DirectoryName -EA 0
                        } Catch {
                            $BasePath = "${env:windir}\LTSVC"
                        }
                    } Else {
                        $BasePath = "${env:windir}\LTSVC"
                    }
                    Add-Member -InputObject $key -MemberType NoteProperty -Name BasePath -Value $BasePath
                }
                $key.BasePath = [System.Environment]::ExpandEnvironmentVariables($($key|Select-Object -Expand BasePath -EA 0)) -replace '\\\\','\'
                If ($Null -ne $key -and ($key|Get-Member|Where-Object {$_.Name -match 'Server Address'})) {
                    $Servers = ($Key|Select-Object -Expand 'Server Address' -EA 0).Split('|')|ForEach-Object {$_.Trim() -replace '~',''}|Where-Object {$_ -match '.+'}
                    Add-Member -InputObject $key -MemberType NoteProperty -Name 'Server' -Value $Servers -Force
                }
            }
            Catch{
                Write-Error "ERROR: Line $(LINENUM): There was a problem reading the registry keys. $($Error[0])"
            }
        }
    }
    End{
        If ($?){
            Write-Debug "Exiting $($myInvocation.InvocationName) at line $(LINENUM)"
            return $key
        } Else {
            Write-Debug "Exiting $($myInvocation.InvocationName) at line $(LINENUM)"
        }
    }
}
Function Get-CWAAInfoBackup {
    [CmdletBinding()]
    [Alias('Get-LTServiceInfoBackup')]
    Param ()
    Begin{
        Write-Verbose "Checking for registry keys."
        $exclude = "PSParentPath","PSChildName","PSDrive","PSProvider","PSPath"
    }
    Process{
        If ((Test-Path 'HKLM:\SOFTWARE\LabTechBackup\Service') -eq $False){
            Write-Error "ERROR: Line $(LINENUM): Unable to find backup information on LTSvc. Use New-CWAABackup to create a settings backup."
            return
        }
        Try{
            $key = Get-ItemProperty HKLM:\SOFTWARE\LabTechBackup\Service -ErrorAction Stop | Select-Object * -exclude $exclude
            If ($Null -ne $key -and ($key|Get-Member|Where-Object {$_.Name -match 'BasePath'})) {
                $key.BasePath = [System.Environment]::ExpandEnvironmentVariables($key.BasePath) -replace '\\\\','\'
            }
            If ($Null -ne $key -and ($key|Get-Member|Where-Object {$_.Name -match 'Server Address'})) {
                $Servers = ($Key|Select-Object -Expand 'Server Address' -EA 0).Split('|')|ForEach-Object {$_.Trim()}
                Add-Member -InputObject $key -MemberType NoteProperty -Name 'Server' -Value $Servers -Force
            }
        }
        Catch{
            Write-Error "ERROR: Line $(LINENUM): There was a problem reading the backup registry keys. $($Error[0])"
            return
        }
    }
    End{
        If ($?){
            return $key
        }
    }
}
Function Get-CWAASettings{
    [CmdletBinding()]
    [Alias('Get-LTServiceSettings')]
    Param ()
    Begin{
        Write-Verbose "Checking for registry keys."
        if ((Test-Path 'HKLM:\SOFTWARE\LabTech\Service\Settings') -eq $False){
            Write-Error "ERROR: Unable to find LTSvc settings. Make sure the agent is installed."
        }
        $exclude = "PSParentPath","PSChildName","PSDrive","PSProvider","PSPath"
    }
    Process{
        Try{
            Get-ItemProperty HKLM:\SOFTWARE\LabTech\Service\Settings -ErrorAction Stop | Select-Object * -exclude $exclude
        }
        Catch{
            Write-Error "ERROR: There was a problem reading the registry keys. $($Error[0])"
        }
    }
    End{
        if ($?){
            $key
        }
    }
}
Function New-CWAABackup{
    [CmdletBinding()]
    [Alias('New-LTServiceBackup')]
    Param ()
    Begin{
        Clear-Variable LTPath,BackupPath,Keys,Path,Result,Reg,RegPath -EA 0 -WhatIf:$False -Confirm:$False #Clearing Variables for use
        Write-Debug "Starting $($myInvocation.InvocationName) at line $(LINENUM)"
        $LTPath = "$(Get-CWAAInfo -EA 0 -Verbose:$False -WhatIf:$False -Confirm:$False -Debug:$False|Select-Object -Expand BasePath -EA 0)"
        if (-not ($LTPath)) {
            Write-Error "ERROR: Line $(LINENUM): Unable to find LTSvc folder path." -ErrorAction Stop
        }
        $BackupPath = "$($LTPath)Backup"
        $Keys = "HKLM\SOFTWARE\LabTech"
        $RegPath = "$BackupPath\LTBackup.reg"
        Write-Verbose "Checking for registry keys."
        if ((Test-Path ($Keys -replace '^(H[^\\]*)','$1:')) -eq $False){
            Write-Error "ERROR: Line $(LINENUM): Unable to find registry information on LTSvc. Make sure the agent is installed." -ErrorAction Stop
        }
        if ($(Test-Path -Path $LTPath -PathType Container) -eq $False) {
            Write-Error "ERROR: Line $(LINENUM): Unable to find LTSvc folder path $LTPath" -ErrorAction Stop
        }
        New-Item $BackupPath -type directory -ErrorAction SilentlyContinue | Out-Null
        if ($(Test-Path -Path $BackupPath -PathType Container) -eq $False) {
            Write-Error "ERROR: Line $(LINENUM): Unable to create backup folder path $BackupPath" -ErrorAction Stop
        }
    }
    Process{
        Try{
            Copy-Item $LTPath $BackupPath -Recurse -Force
        }
        Catch{
            Write-Error "ERROR: Line $(LINENUM): There was a problem backing up the LTSvc Folder. $($Error[0])"
        }
        Try{
            Write-Debug "Line $(LINENUM): Exporting Registry Data"
            $Null = & "$env:windir\system32\reg.exe" export "$Keys" "$RegPath" /y 2>''
            Write-Debug "Line $(LINENUM): Loading and modifying registry key name"
            $Reg = Get-Content $RegPath
            $Reg = $Reg -replace [Regex]::Escape('[HKEY_LOCAL_MACHINE\SOFTWARE\LabTech'),'[HKEY_LOCAL_MACHINE\SOFTWARE\LabTechBackup'
            Write-Debug "Line $(LINENUM): Writing output information"
            $Reg | Out-File $RegPath
            Write-Debug "Line $(LINENUM): Importing Registry data to Backup Path"
            $Null = & "$env:windir\system32\reg.exe" import "$RegPath" 2>''
            $True | Out-Null #Protection to prevent exit status error
        }
        Catch{
            Write-Error "ERROR: Line $(LINENUM): There was a problem backing up the LTSvc Registry keys. $($Error[0])"
        }
    }
    End{
        If ($?){
            Write-Output "The LabTech Backup has been created."
        } Else {
            Write-Error "ERROR: Line $(LINENUM): There was a problem completing the LTSvc Backup. $($Error[0])"
        }
        Write-Debug "Exiting $($myInvocation.InvocationName) at line $(LINENUM)"
    }
}
Function Reset-CWAA{
    [CmdletBinding(SupportsShouldProcess=$True)]
    [Alias('Reset-LTService')]
    Param(
        [switch]$ID,
        [switch]$Location,
        [switch]$MAC,
        [switch]$Force,
        [switch]$NoWait
    )
    Begin{
        Write-Debug "Starting $($myInvocation.InvocationName) at line $(LINENUM)"
        $Reg = 'HKLM:\Software\LabTech\Service'
        If (!$PsBoundParameters.ContainsKey('ID') -and !$PsBoundParameters.ContainsKey('Location') -and !$PsBoundParameters.ContainsKey('MAC')){
            $ID=$True
            $Location=$True
            $MAC=$True
        }
        $LTSI=Get-CWAAInfo -EA 0 -Verbose:$False -WhatIf:$False -Confirm:$False -Debug:$False
        If (($LTSI) -and ($LTSI|Select-Object -Expand Probe -EA 0) -eq '1') {
            If ($Force -eq $True) {
                Write-Output "Probe Agent Detected. Reset Forced."
            } Else {
                If ($WhatIfPreference -ne $True) {
                    Write-Error -Exception [System.OperationCanceledException]"ERROR: Line $(LINENUM): Probe Agent Detected. Reset Denied." -ErrorAction Stop
                } Else {
                    Write-Error -Exception [System.OperationCanceledException]"What If: Line $(LINENUM): Probe Agent Detected. Reset Denied." -ErrorAction Stop
                }
            }
        }
        Write-Output "OLD ID: $($LTSI|Select-Object -Expand ID -EA 0) LocationID: $($LTSI|Select-Object -Expand LocationID -EA 0) MAC: $($LTSI|Select-Object -Expand MAC -EA 0)"
        $LTSI=$Null
    }
    Process{
        If (!(Get-Service 'LTService','LTSvcMon' -ErrorAction SilentlyContinue)) {
            If ($WhatIfPreference -ne $True) {
                Write-Error "ERROR: Line $(LINENUM): LabTech Services NOT Found $($Error[0])"
                return
            } Else {
                Write-Error "What If: Line $(LINENUM): Stopping: LabTech Services NOT Found"
                return
            }
        }
        Try{
            If ($ID -or $Location -or $MAC) {
                Stop-CWAA
                If ($ID) {
                    Write-Output ".Removing ID"
                    Remove-ItemProperty -Name ID -Path $Reg -ErrorAction SilentlyContinue
                }
                If ($Location) {
                    Write-Output ".Removing LocationID"
                    Remove-ItemProperty -Name LocationID -Path $Reg -ErrorAction SilentlyContinue
                }
                If ($MAC) {
                    Write-Output ".Removing MAC"
                    Remove-ItemProperty -Name MAC -Path $Reg -ErrorAction SilentlyContinue
                }
                Start-CWAA
            }
        }
        Catch{
            Write-Error "ERROR: Line $(LINENUM): There was an error during the reset process. $($Error[0])" -ErrorAction Stop
        }
    }
    End{
        If ($?){
            If (-NOT $NoWait -and $PSCmdlet.ShouldProcess("LTService", "Discover new settings after Service Start")) {
                $timeout = New-Timespan -Minutes 1
                $sw = [diagnostics.stopwatch]::StartNew()
                $LTSI=Get-CWAAInfo -EA 0 -Verbose:$False -WhatIf:$False -Confirm:$False -Debug:$False
                Write-Host -NoNewline "Waiting for agent to register."
                While (!($LTSI|Select-Object -Expand ID -EA 0) -or !($LTSI|Select-Object -Expand LocationID -EA 0) -or !($LTSI|Select-Object -Expand MAC -EA 0) -and $($sw.elapsed) -lt $timeout){
                    Write-Host -NoNewline '.'
                    Start-Sleep 2
                    $LTSI=Get-CWAAInfo -EA 0 -Verbose:$False -WhatIf:$False -Confirm:$False -Debug:$False
                }
                Write-Host ""
                $LTSI=Get-CWAAInfo -EA 0 -Verbose:$False -WhatIf:$False -Confirm:$False -Debug:$False
                Write-Output "NEW ID: $($LTSI|Select-Object -Expand ID -EA 0) LocationID: $($LTSI|Select-Object -Expand LocationID -EA 0) MAC: $($LTSI|Select-Object -Expand MAC -EA 0)"
            }
        } Else {$Error[0]}
        Write-Debug "Exiting $($myInvocation.InvocationName) at line $(LINENUM)"
    }
}
Initialize-CWAA
