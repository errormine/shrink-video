# shrink

Compress a video to fit under a size limit (default 10 MB) with ffmpeg two-pass encoding.
AV1 + Opus by default, H.264 + AAC with `-h264`. Frame rate is capped at 30 fps and the
resolution is picked from the available bitrate.

## Requirements

- Windows PowerShell 5.1+
- `ffmpeg` and `ffprobe` on PATH, with `libsvtav1` and `libopus` (default) or `libx264` (`-h264`)

## Install

Put `shrink.ps1` and `shrink.cmd` in a folder on your PATH, then optionally add the
Explorer right-click menu:

```
shrink -install
```

Run `-install` / `-uninstall` from your own terminal. The menu is a "Shrink video" submenu
on video files (`.mp4 .mkv .mov .avi .webm .m4v .wmv .flv .ts .mts .m2ts`) with 10, 25, 50
and 100 MB targets. Each item shows the longest clip that still gets 1080p at that size.

## Usage

```
shrink clip.mp4              under 10 MB
shrink clip.mp4 25           under 25 MB
shrink *.mp4 50              every mp4 in the folder (PowerShell)
shrink clip.mp4 -h264        H.264 + AAC, plays on anything
shrink clip.mp4 -height 720  force 720p (never upscales)
shrink clip.mp4 -fps 60      allow up to 60 fps
shrink clip.mp4 -dryrun      print the plan and ffmpeg commands, encode nothing
shrink -help                 all options
```

Output goes next to the input as `<name>_<height>p<fps>_<MB>MB.mp4`. If the result is
over the limit, it retries at a lower bitrate (up to 3 attempts).
