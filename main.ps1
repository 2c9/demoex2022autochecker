﻿function compress {
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
        'rm -f $PLAY'
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
      ) -join ';'
    }
    return $vmscript
}

$vcsa = "vcsacluster.ouiit.local"
Connect-VIServer -Server $vcsa

$CLI = Get-VM -Name "TF-CLI-0"
$vmscript = Get-Content -Path .\CLI.ps1 -Raw | compress | payload -Win
$out = Invoke-VMScript -VM $CLI -ScriptText $vmscript -GuestUser 'user' -GuestPassword 'Pa$$w0rd' -ScriptType Powershell
$out.ScriptOutput | ConvertFrom-Json

##################

$ISP = Get-VM -Name "TF-ISP-0"
$vmscript = Get-Content -Path .\ISP.yaml -Raw | compress | payload -Linux
$out = Invoke-VMScript -VM $ISP -ScriptText $vmscript -GuestUser 'root' -GuestPassword 'toor' -ScriptType Bash
$out.ScriptOutput | ConvertFrom-Json

###################

$WEBL = Get-VM -Name "TF-WEB-L-0"
$vmscript = Get-Content -Path .\WEBL.yaml -Raw | compress | payload -Linux
$out = Invoke-VMScript -VM $WEBL -ScriptText $vmscript -GuestUser 'root' -GuestPassword 'toor' -ScriptType Bash
$out.ScriptOutput | ConvertFrom-Json

Disconnect-VIServer -Server $vcsa -Confirm:$false
