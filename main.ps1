$vcsa = "vcsacluster.ouiit.local"
Connect-VIServer -Server $vcsa

$CLI = Get-VM -Name CLI-XX
$script = Get-Content -Path .\CLI.ps1 -Raw

$Data= foreach ($c in $script.ToCharArray()) { $c -as [Byte] }
$ms = New-Object IO.MemoryStream
$cs = New-Object System.IO.Compression.GZipStream ($ms, [Io.Compression.CompressionMode]"Compress")
$cs.Write($Data, 0, $Data.Length)
$cs.Close()
$scripttext=[Convert]::ToBase64String($ms.ToArray())
$ms.Close()

$vmscript=@'
$scripttext="{0}"
$binaryData = [System.Convert]::FromBase64String($scripttext)
$ms = New-Object System.IO.MemoryStream
$ms.Write($binaryData, 0, $binaryData.Length)
$ms.Seek(0,0) | Out-Null
$cs = New-Object System.IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]"Decompress")
$sr = New-Object System.IO.StreamReader($cs)
$sr.ReadToEnd() | Invoke-Expression
'@ -f $scripttext

$out = Invoke-VMScript -VM $CLI -ScriptText $vmscript -GuestUser 'Admin' -GuestPassword 'Pa$$w0rd' -ScriptType Powershell
$out.ScriptOutput | ConvertFrom-Json

Disconnect-VIServer -Server $vcsa -Confirm:$false
