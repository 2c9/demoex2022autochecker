function compress {
    [OutputType([String])]
    [CmdletBinding()]
    param (
        [Parameter(ParameterSetName='script',
                   Mandatory=$true,
                   ValueFromPipeline=$true)]
        [string]$script
    )
    $Data= foreach ($c in $script.ToCharArray()) { $c -as [Byte] }
    $ms = New-Object IO.MemoryStream
    $cs = New-Object System.IO.Compression.GZipStream ($ms, [Io.Compression.CompressionMode]"Compress")
    $cs.Write($Data, 0, $Data.Length)
    $cs.Close()
    [Convert]::ToBase64String($ms.ToArray())
    $ms.Close()
}

function payload {
    [OutputType([String])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,ValueFromPipeline,ValueFromPipelineByPropertyName)]
        [string]$script,
        [switch]$Linux,
        [switch]$Win
    )
    if($Linux){
      $vmscript = @(
        'PLAY=$(mktemp)'
        'echo {0} | base64 -d | zcat > $PLAY' -f $script
        'ANSIBLE_STDOUT_CALLBACK=json ansible-playbook --check -i localhost, -c local $PLAY | jq ''[.plays[].tasks[1:][]|{(.task.name):.hosts.localhost.changed|not}]|add'''
        '#rm -f $PLAY'
      ) -join ';'
    }
    if($Win){
      $vmscript = @(
        '$scripttext="{0}"' -f $script
        '$binaryData = [System.Convert]::FromBase64String($scripttext)'
        '$ms = New-Object System.IO.MemoryStream'
        '$ms.Write($binaryData, 0, $binaryData.Length)'
        '$ms.Seek(0,0) | Out-Null'
        '$cs = New-Object System.IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]"Decompress")'
        '$sr = New-Object System.IO.StreamReader($cs)'
        '$sr.ReadToEnd() | Invoke-Expression'
      ) | Out-String
    }
    return $vmscript
}

$vcsa = "vcsacluster.ouiit.local"
Connect-VIServer -Server $vcsa

$CLI = Get-VM -Name "TF-CLI-0"
$vmscript = Get-Content -Path .\CLI.ps1 -Raw | compress | payload -Win
$out = Invoke-VMScript -VM $CLI -ScriptText $vmscript -GuestUser 'user' -GuestPassword 'Pa$$w0rd' -ScriptType Powershell
$CLI_OUT = $out.ScriptOutput | ConvertFrom-Json

##################

$SRV = Get-VM -Name "TF-SRV-0"
$vmscript = Get-Content -Path .\SRV.ps1 -Raw | compress | payload -Win
$out = Invoke-VMScript -VM $SRV -ScriptText $vmscript -GuestUser 'Administrator' -GuestPassword 'Pa$$w0rd' -ScriptType Powershell
$SRV_OUT = $out.ScriptOutput | ConvertFrom-Json

##################

$ISP = Get-VM -Name "TF-ISP-0"
$vmscript = Get-Content -Path .\ISP.yaml -Raw | compress | payload -Linux
$out = Invoke-VMScript -VM $ISP -ScriptText $vmscript -GuestUser 'root' -GuestPassword 'toor' -ScriptType Bash
$ISP_OUT = $out.ScriptOutput | ConvertFrom-Json

###################

$WEBL = Get-VM -Name "TF-WEB-L-0"
$vmscript = Get-Content -Path .\WEBL.yaml -Raw | compress | payload -Linux
$out = Invoke-VMScript -VM $WEBL -ScriptText $vmscript -GuestUser 'root' -GuestPassword 'toor' -ScriptType Bash
$WEBL_OUT = $out.ScriptOutput | ConvertFrom-Json

###################

$WEBR = Get-VM -Name "TF-WEB-R-0"
$vmscript = Get-Content -Path .\WEBR.yaml -Raw | compress | payload -Linux
$out = Invoke-VMScript -VM $WEBR -ScriptText $vmscript -GuestUser 'root' -GuestPassword 'toor' -ScriptType Bash
$WEBR_OUT = $out.ScriptOutput | ConvertFrom-Json

#####################################

$result = @(
    [pscustomobject]@{
        "Name" = "A: Basic configuration"; "Max" = 0.3; "Mark" = if($CLI_OUT.hostname -and
                                                                    $SRV_OUT.hostname -and
                                                                    $ISP_OUT.hostname -and
                                                                    $WEBL_OUT.hostname -and
                                                                    $WEBR_OUT.hostname)
                                                                    { 0.3 } else { 0 }
    },
    [pscustomobject]@{
        "Name" = "A: Network configuration"; "Max" = 0.5; "Mark" = if( $CLI_OUT.netconf -and 
                                                                       $SRV_OUT.netconf -and
                                                                       $WEBR_OUT.ens192 -and
                                                                       $WEBL_OUT.ens192 -and
                                                                       ( $ISP_OUT.ens192 -and $ISP_OUT.ens224 -and $ISP_OUT.ens256) -and
                                                                       ( $ISP_OUT.ip_forward -and $WEBL_OUT.gw -and $WEBR_OUT.gw ))
                                                                       { 0.5 } else { 0 }
    },
    [pscustomobject]@{
        "Name" = "B: Only connected networks in the route table on ISP"; "Max" = 0.3; "Mark" = if ( $ISP_OUT.connected_only ){ 0.3 } else { 0 }
    },
    [pscustomobject]@{
        "Name" = "B: The Left and the Right offices have connectivity"; "Max" = 1; "Mark" = if(      $WEBL_OUT.tunnel -and
                                                                                                     $WEBR_OUT.tunnel -and
                                                                                                     $ISP_OUT.connected_only ) { 1 }
                                                                                            elseif ( $WEBL_OUT.tunnel -and
                                                                                                     $WEBR_OUT.tunnel        ) { 0.5 }
                                                                                            else    { 0 }
    },
    [pscustomobject]@{
        "Name" = "B: ICMP from WEB-L to RTR-R"; "Max" = 0.5; "Mark" = if( $WEBL_OUT.inet ){ 0.5 } else { 0 }
    },
    [pscustomobject]@{
        "Name" = "B: ICMP from WEB-R to RTR-L"; "Max" = 0.5; "Mark" = if( $WEBR_OUT.inet ){ 0.5 } else { 0 }
    },
    [pscustomobject]@{
        "Name" = "B: RTR-L has a forwarding rule for SSH from 2222 to WEB-L "; "Max" = 0.5; "Mark" = if ( $ISP_OUT.ssh_left ) { 0.5 } else { 0 };
    },
    [pscustomobject]@{
        "Name" = "B: RTR-R has a forwarding rule for SSH from 2244 to WEB-R "; "Max" = 0.5; "Mark" = if ( $ISP_OUT.ssh_right ) { 0.5 } else { 0 };
    },
    [pscustomobject]@{
        "Name" = "C: CLI has HTTP access to the application via RTR-L and RTR-R"; "Max" = 0.5; "Mark" = if ( $CLI_OUT.http ) { 0.5 } else { 0 }
    },
    [pscustomobject]@{
        "Name" = "C: CLI has HTTPS access to the application via RTR-L and RTR-R"; "Max" = 0.5; "Mark" = if ( $CLI_OUT.https ) { 0.5 } else { 0 }
    },
    [pscustomobject]@{
        "Name" = "C: HTTP redirects to HTTPS"; "Max" = 0.5; "Mark" = if ( $CLI_OUT.redirections ) { 0.5 } else { 0 }
    },
    [pscustomobject]@{
        "Name" = "C: ISP manges demo.wsr zone and CLI can resolve dns names"; "Max" = 1; "Mark" = if ( $CLI_OUT.dns ) { 1 } else { 0 }
    },
    [pscustomobject]@{
        "Name" = "C: SRV manges int.demo.wsr zone"; "Max" = 0.5; "Mark" = if ( $SRV_OUT.dnsrecord ) { 0.5 } else { 0 }
    },
    [pscustomobject]@{
        "Name" = "C: SRV has reverse zones"; "Max" = 0.5; "Mark" = if ( $SRV_OUT.dns_rzone_left -and -$SRV_OUT.dns_rzone_right ) { 0.5 } else { 0 }
    },
    [pscustomobject]@{
        "Name" = "C: WEB-L and WEB-R use SRV as DNS server"; "Max" = 0.5; "Mark" = if ( $WEBL_OUT.nameserver -and -$WEBR_OUT.nameserver ) { 0.5 } else { 0 }
    },
    [pscustomobject]@{
        "Name" = "C: Chrony is installed on ISP and the stratum=4"; "Max" = 0.5; "Mark" = if ( $ISP_OUT.chronyd_installed -and $ISP_OUT.chronyd_stratum ) { 0.5 } else { 0 }
    },
    [pscustomobject]@{
        "Name" = "C: CLI uses ISP as NTP server"; "Max" = 0.3; "Mark" = if ( $CLI_OUT.ntp ) { 0.3 } else { 0 }
    },
    [pscustomobject]@{
        "Name" = "C: SRV uses ISP as NTP server"; "Max" = 0.3; "Mark" = if ( $SRV_OUT.ntp ) { 0.3 } else { 0 }
    },
    [pscustomobject]@{
        "Name" = "C: SRV has RAID Mirror"; "Max" = 0.5; "Mark" = if ( $SRV_OUT.raid -and $SRV_OUT.drive_letter ) { 0.5 } else { 0 }
    },
    [pscustomobject]@{
        "Name" = "C: SRV has NFS share"; "Max" = 0.3; "Mark" = if ( $SRV_OUT.nfs_share ) { 0.3 } else { 0 }
    },
    [pscustomobject]@{
        "Name" = "C: WEB-L and WEB-R connected to NFS"; "Max" = 0.3; "Mark" = if ( $SRV_OUT.nfs_clients ) { 0.3 } else { 0 }
    },
    [pscustomobject]@{
        "Name" = "C: CA is configured"; "Max" = 1; "Mark" = if ( $SRV_OUT.ca ) { 1 } else { 0 }
    },
    [pscustomobject]@{
        "Name" = "C: CA certificate expiration"; "Max" = 1; "Mark" = if ( $SRV_OUT.ca_days ) { 1 } else { 0 }
    },
    [pscustomobject]@{
        "Name" = "D: Docker is installed on WEB-L"; "Max" = 0.3; "Mark" = if ( $WEBL_OUT.docker) { 0.3 } else { 0 }
    },
    [pscustomobject]@{
        "Name" = "D: Docker is installed on WEB-R"; "Max" = 0.3; "Mark" = if ( $WEBR_OUT.docker) { 0.3 } else { 0 }
    },
    [pscustomobject]@{
        "Name" = "D: The application image is loaded on WEB-L"; "Max" = 0.3; "Mark" = if ( $WEBL_OUT.docker_image) { 0.3 } else { 0 }
    },
    [pscustomobject]@{
        "Name" = "D: The application image is loaded on WEB-R"; "Max" = 0.3; "Mark" = if ( $WEBR_OUT.docker_image) { 0.3 } else { 0 }
    },
    [pscustomobject]@{
        "Name" = "D: The application container is running on WEB-L"; "Max" = 0.3; "Mark" = if ( $WEBL_OUT.docker_container) { 0.3 } else { 0 }
    },
    [pscustomobject]@{
        "Name" = "D: The application container is running on WEB-R"; "Max" = 0.3; "Mark" = if ( $WEBR_OUT.docker_container) { 0.3 } else { 0 }
    }
)
$result | Format-Table

Disconnect-VIServer -Server $vcsa -Confirm:$false
