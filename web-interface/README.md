# MediaControl Web Interface

Node/Express control panel for the H.265 conversion scripts in this repository.

## Features

- Start the full conversion runner in a tmux session
- Stop the active tmux conversion session
- Trigger the weekly wrapper
- View script/config status
- Browse and tail conversion logs
- Authenticate with local PAM/Proxmox credentials

## Install

```bash
cd web-interface
npm install
PORT=8016 npm start
```

Run from the repository root if you want the default paths to work. The app defaults to:

- `../movie-transcode.env`
- `../transcode-logs`
- `../scripts/run_movie_transcode_all.sh`
- `../scripts/weekly_movie_transcode_cron.sh`

## Environment

- `PORT`: HTTP port, default `8006`
- `MEDIA_CONTROL_TMUX_SESSION`: tmux session name, default `media_h265`
- `MEDIA_CONTROL_LOG_DIR`: log directory
- `MEDIA_CONTROL_ENV`: transcode environment file
- `MEDIA_CONTROL_RUNNER`: full conversion runner script
- `MEDIA_CONTROL_CRON_WRAPPER`: weekly wrapper script
- `MEDIA_CONTROL_PAM_SERVICE`: PAM service, default `proxmox-ve-auth`

## systemd Example

```ini
[Unit]
Description=MediaControl H.265 conversion control panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/H265Converter/web-interface
Environment=PORT=8016
Environment=MEDIA_CONTROL_ENV=/opt/H265Converter/movie-transcode.env
Environment=MEDIA_CONTROL_LOG_DIR=/opt/H265Converter/transcode-logs
ExecStart=/usr/bin/node /opt/H265Converter/web-interface/server.js
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
```

