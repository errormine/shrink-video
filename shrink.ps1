<#
.SYNOPSIS
  shrink - compress a video to fit under a size limit with ffmpeg. Run "shrink -help" for usage.
#>
param(
    [Parameter(Position = 0)][string[]]$Path,
    [Parameter(Position = 1)][double]$TargetMB = 10,
    [int]$Height = 0,      # 0 = pick from bitrate
    [int]$Fps = 30,
    [switch]$H264,
    [switch]$Av1,          # kept so old "-av1" calls still work; AV1 is the default
    [switch]$DryRun,
    [switch]$Pause,
    [switch]$Install,
    [switch]$Uninstall,
    [Alias('h')][switch]$Help,
    [switch]$Version
)

$ShrinkVersion = '1.1.0'
$MenuSizes     = 10, 25, 50, 100
$MenuExts      = '.mp4', '.mkv', '.mov', '.avi', '.webm', '.m4v', '.wmv', '.flv', '.ts', '.mts', '.m2ts'
$MenuKeyName   = 'ShrinkVideo'

function Show-Usage {
@"
shrink $ShrinkVersion - compress a video to fit under a size limit (ffmpeg, two-pass)

USAGE
  shrink <file> [MB] [options]

EXAMPLES
  shrink clip.mp4              under 10 MB (default)
  shrink clip.mp4 25           under 25 MB
  shrink *.mp4 50              every mp4 in the folder, under 50 MB each
  shrink clip.mp4 -dryrun      show what would run, encode nothing

ENCODE OPTIONS
  -h264          H.264 + AAC instead of AV1 + Opus (plays on anything, lower quality per MB)
  -height <n>    force output height, e.g. 720 (never upscales; default: automatic)
  -fps <n>       max frame rate (default 30)
  -dryrun        print the plan and ffmpeg commands without encoding
  -pause         keep the window open at the end (used by the right-click menu)

PROGRAM OPTIONS
  -install       add a "Shrink video" submenu to the Explorer right-click menu ($($MenuSizes -join ', ') MB)
  -uninstall     remove the right-click menu
  -version       print the version
  -help, -h      show this help

Output is saved next to the input as <name>_<height>p<fps>_<MB>MB.mp4.
On Windows 11 the menu is under "Show more options" (or Shift + right-click).
"@ | Write-Host
}

function Update-Explorer {
    # SHCNE_ASSOCCHANGED: tell Explorer file associations changed so the menu updates without a restart.
    try {
        Add-Type -Namespace Shrink -Name Shell -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int e, uint f, System.IntPtr a, System.IntPtr b);' -ErrorAction Stop
        [Shrink.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
    } catch {}
}

function Remove-Menu {
    $removed = 0
    # Current location, plus the SystemFileAssociations keys older versions wrote.
    $star = 'HKCU:\Software\Classes\*\shell'
    $roots = @(Get-ChildItem -LiteralPath $star -ErrorAction SilentlyContinue |
               Where-Object { $_.PSChildName -like "$MenuKeyName*" } | ForEach-Object { "$star\$($_.PSChildName)" }) +
             @("HKCU:\Software\Classes\SystemFileAssociations\video\shell\$MenuKeyName") +
             ($MenuExts | ForEach-Object { "HKCU:\Software\Classes\SystemFileAssociations\$_\shell\$MenuKeyName" })
    foreach ($k in $roots) { if (Test-Path -LiteralPath $k) { Remove-Item -LiteralPath $k -Recurse -Force; $removed++ } }
    Update-Explorer
    return $removed
}

# Rough guide for the menu: the longest clip that still gets 1080p at this size.
# Mirrors the encode logic below (AV1: 1080p from 2500/1.6 kbps video; 64k Opus).
function Get-MenuLabel([double]$mb) {
    $budget = $mb * 0.95 * 8000
    $t1080  = $budget / (2500 / 1.6 + 64)
    $s = [int]([math]::Floor($t1080 / 5) * 5)
    "$mb MB - 1080p up to {0}:{1:D2}" -f [int][math]::Floor($s / 60), ($s % 60)
}

function Install-Menu {
    [void](Remove-Menu)
    $ps1 = $PSCommandPath
    # Registered on "*" (all files) and filtered with AppliesTo: on some setups Explorer ignores
    # SystemFileAssociations\<ext> verbs when the default app is a Store app.
    # All registry paths are literal: "*" here is a key name, not a wildcard.
    # One "Shrink video" submenu on all files, shown only for video extensions via AppliesTo.
    # The script also rejects non-videos, in case the filter is ignored.
    $root = "HKCU:\Software\Classes\*\shell\$MenuKeyName"
    $appliesTo = ($MenuExts | ForEach-Object { "System.FileExtension:=$_" }) -join ' OR '
    New-Item -Path $root -Force | Out-Null
    Set-ItemProperty -LiteralPath $root -Name 'MUIVerb'     -Value 'Shrink video'
    Set-ItemProperty -LiteralPath $root -Name 'SubCommands' -Value ''
    Set-ItemProperty -LiteralPath $root -Name 'Icon'        -Value 'imageres.dll,-23'
    Set-ItemProperty -LiteralPath $root -Name 'AppliesTo'   -Value $appliesTo
    $i = 0
    foreach ($mb in $MenuSizes) {
        $i++
        $key = "$root\shell\{0:D2}_{1}MB" -f $i, $mb
        New-Item -Path $key -Force -Value (Get-MenuLabel $mb) | Out-Null
        $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ps1`" `"%1`" $mb -Pause"
        New-Item -Path "$key\command" -Force -Value $cmd | Out-Null
    }
    Update-Explorer
    Write-Host "Installed the 'Shrink video' submenu for: $($MenuExts -join ' ')" -ForegroundColor Green
    Write-Host "Windows 11 menu: they are under 'Show more options'."
}

if ($Help)      { Show-Usage; return }
if ($Version)   { Write-Host "shrink $ShrinkVersion"; return }
if ($Uninstall) { $n = Remove-Menu; Write-Host $(if ($n) { "Removed the right-click menu." } else { "The right-click menu was not installed." }); return }
if ($Install)   { Install-Menu; return }
if (-not $Path) { Show-Usage; exit 1 }

$Av1 = -not $H264
$env:SVT_LOG = '1'   # SVT-AV1: errors only, no info banner

# Not 'Stop': ffmpeg writes progress to stderr, which PowerShell 5.1 would turn into a fatal error when redirected.
$ErrorActionPreference = 'Continue'
$failed = $false

function Fail($msg) { Write-Host $msg -ForegroundColor Red; $script:failed = $true }
function Format-Cmd($argList) { 'ffmpeg ' + (($argList | ForEach-Object { if ("$_" -match '\s') { "`"$_`"" } else { "$_" } }) -join ' ') }

foreach ($pattern in $Path) {
  $items = if (Test-Path -LiteralPath $pattern) { Get-Item -LiteralPath $pattern } else { Get-Item -Path $pattern -ErrorAction SilentlyContinue }
  if (-not $items) { Fail "No file matches: $pattern"; continue }
  foreach ($item in $items) {
    $in = $item.FullName
    if ($item.PSIsContainer -or $MenuExts -notcontains $item.Extension.ToLower()) {
        Fail "Not a video file: $($item.Name)  (supported: $($MenuExts -join ' '))"
        continue
    }
    try { $Host.UI.RawUI.WindowTitle = "shrink: $($item.Name)" } catch {}

    $duration = [double](& ffprobe -v error -show_entries format=duration -of csv=p=0 "$in")
    $srcH     = [int](& ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$in")
    $fpsRaw   = (& ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$in")
    $hasAudio = [bool](& ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$in")
    if ($duration -le 0 -or -not $fpsRaw) { Fail "Could not read video info from $in"; continue }
    $fpsParts = $fpsRaw.Split('/'); $srcFps = [double]$fpsParts[0] / [double]$fpsParts[1]

    # Aim a bit under the limit (container overhead, rate-control drift). 1 MB = 1,000,000 bytes,
    # so the result is also under the limit if the site counts in MiB.
    $budgetKbit = $TargetMB * 0.95 * 8000
    $audioKbps  = if (-not $hasAudio) { 0 } elseif ($Av1) { 64 } else { 96 }
    $scale = 1.0
    $out = $null

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $videoKbps = [math]::Floor(($budgetKbit * $scale) / $duration - $audioKbps)
        if ($videoKbps -lt 100) {
            Fail "Video is too long to fit in $TargetMB MB at watchable quality ($([math]::Round($duration))s)."
            break
        }

        # Resolution: forced by -Height, or picked from the bitrate.
        # AV1 needs roughly half the bitrate of H.264 for the same quality.
        if ($Height -gt 0) { $maxH = $Height }
        else {
            $eff  = if ($Av1) { $videoKbps * 1.6 } else { $videoKbps }
            $maxH = if ($eff -lt 800) { 480 } elseif ($eff -lt 2500) { 720 } else { 1080 }
        }
        $outH   = [math]::Min($srcH, $maxH)
        $outFps = [int][math]::Round([math]::Min($srcFps, $Fps))

        $filters = @()
        if ($srcH -gt $maxH) { $filters += "scale=-2:$maxH" }
        if ($srcFps -gt $Fps + 1) { $filters += "fps=$Fps" }
        $vf = if ($filters) { @('-vf', ($filters -join ',')) } else { @() }

        $tag = "${outH}p${outFps}_$($TargetMB)MB" + $(if ($Av1) { '' } else { '_h264' })
        if (-not $DryRun -and $out -and (Test-Path -LiteralPath $out)) { Remove-Item -LiteralPath $out }   # earlier attempt
        $out = Join-Path $item.DirectoryName ("$($item.BaseName)_$tag.mp4")

        Write-Host "[$($item.Name)] $([math]::Round($duration,1))s, attempt $attempt : $(if ($Av1) {'AV1'} else {'H.264'}) ${videoKbps}k video + ${audioKbps}k audio, ${outH}p @ ${outFps}fps" -ForegroundColor Cyan

        $log = Join-Path $env:TEMP ("shrink_" + [guid]::NewGuid().ToString('N'))
        if ($Av1) {
            $codec = @('-c:v', 'libsvtav1', '-preset', '5', '-b:v', "${videoKbps}k",
                       '-svtav1-params', 'tune=0', '-g', '300', '-pix_fmt', 'yuv420p10le')
        } else {
            $codec = @('-c:v', 'libx264', '-preset', 'slow', '-b:v', "${videoKbps}k",
                       '-maxrate', "$([math]::Floor($videoKbps * 1.5))k", '-bufsize', "$($videoKbps * 2)k",
                       '-pix_fmt', 'yuv420p')
        }
        $common = @('-hide_banner', '-loglevel', 'error', '-stats', '-y', '-i', $in) + $vf + $codec +
                  @('-passlogfile', $log)
        $audio = if (-not $hasAudio) { @('-an') }
                 elseif ($Av1) { @('-c:a', 'libopus', '-b:a', "${audioKbps}k") }
                 else { @('-c:a', 'aac', '-b:a', "${audioKbps}k") }
        $pass1 = $common + @('-pass', '1', '-an', '-f', 'null', 'NUL')
        $pass2 = $common + @('-pass', '2') + $audio + @('-movflags', '+faststart', $out)

        if ($DryRun) {
            Write-Host "  output: $out"
            Write-Host "  $(Format-Cmd $pass1)" -ForegroundColor DarkGray
            Write-Host "  $(Format-Cmd $pass2)" -ForegroundColor DarkGray
            break
        }

        & ffmpeg @pass1
        if ($LASTEXITCODE -ne 0) { Remove-Item "$log*" -ErrorAction SilentlyContinue; Fail "ffmpeg pass 1 failed"; break }

        & ffmpeg @pass2
        $ok = $LASTEXITCODE -eq 0
        Remove-Item "$log*" -ErrorAction SilentlyContinue
        if (-not $ok) { Fail "ffmpeg pass 2 failed"; break }

        $sizeMB = (Get-Item -LiteralPath $out).Length / 1MB * 1.048576   # bytes / 1,000,000
        if ($sizeMB -le $TargetMB) {
            Write-Host ("Done: {0}  ({1:N2} MB)" -f $out, $sizeMB) -ForegroundColor Green
            break
        }
        Write-Host ("Result {0:N2} MB is over {1} MB, retrying smaller..." -f $sizeMB, $TargetMB) -ForegroundColor Yellow
        $scale *= ($TargetMB / $sizeMB) * 0.95
        if ($attempt -eq 3) { Fail "Could not get under $TargetMB MB." }
    }
  }
}

if ($Pause) {
    if ($failed) { Read-Host "Something went wrong. Press Enter to close" | Out-Null }
    else { Write-Host "Closing in 5 seconds..."; Start-Sleep 5 }
}
if ($failed) { exit 1 }
