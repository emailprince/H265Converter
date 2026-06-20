# H265Converter

Shell tooling for converting movie and TV media to H.265/HEVC MKV files with FFmpeg VAAPI hardware encoding.

## What it does

- Converts common video containers to `.h265.mkv` using `hevc_vaapi`
- Remuxes existing HEVC files into MKV when needed
- Preserves audio, subtitles, metadata, and chapters where possible
- Adds an AC-3 5.1 fallback track when the first audio track is not Apple TV friendly
- Verifies output codec, Matroska container, and duration before deleting the original file
- Handles Blu-ray/DVD ISO sources by mounting and extracting the main title
- Includes helper scripts for filename standardization, duplicate scans, weekly tmux runs, and optional Plex refresh

## Requirements

- Linux host with VAAPI-capable GPU exposed under `/dev/dri`
- `bash`
- `ffmpeg` and `ffprobe`
- `find`, `awk`, `sort`, `stat`, `mount`, `umount`
- `tmux` for the weekly runner
- `curl` for optional Plex refresh

## Setup

```bash
git clone https://github.com/emailprince/H265Converter.git
cd H265Converter
cp movie-transcode.env.example movie-transcode.env
```

Edit `movie-transcode.env` for your library paths, GPU device, quality, and log directory.

## Usage

Convert one library:

```bash
LIBRARY=/path/to/media ./scripts/transcode_movies_h265_vaapi.sh
```

Run movies, TV, ISOs, filename standardization, and Plex refresh:

```bash
./scripts/run_movie_transcode_all.sh
```

Dry run:

```bash
DRY_RUN=1 LIBRARY=/path/to/media ./scripts/transcode_movies_h265_vaapi.sh
```

Scan for duplicate or suspicious movie files:

```bash
LIBRARY=/path/to/movies ./scripts/scan_movie_duplicates.sh
```

Standardize movie filenames to match the parent folder:

```bash
DRY_RUN=1 LIBRARY=/path/to/movies ./scripts/standardize_movie_filenames.sh
DRY_RUN=0 LIBRARY=/path/to/movies ./scripts/standardize_movie_filenames.sh
```

Run weekly in tmux:

```bash
./scripts/weekly_movie_transcode_cron.sh
```

## Web Interface

The `web-interface/` folder contains the MediaControl Node.js control panel for starting/stopping the H.265 runner and viewing logs.

```bash
cd web-interface
npm install
PORT=8016 npm start
```

## Configuration

The scripts read `movie-transcode.env` from the repo root by default. You can point to another file with:

```bash
MOVIE_TRANSCODE_CONFIG=/path/to/movie-transcode.env ./scripts/run_movie_transcode_all.sh
```

Plex refresh reads `plex-refresh.env` from the repo root by default, or another file via `PLEX_REFRESH_CONFIG`.

## Safety Notes

After a successful encode or remux, the original source file is deleted only after output verification passes. Test with `DRY_RUN=1` and a small sample library before running against a full collection.
