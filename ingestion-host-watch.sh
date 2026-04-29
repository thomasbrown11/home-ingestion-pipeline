#SAVE THIS TO /usr/local/bin/ingestion-host-watch.sh

#!/bin/bash

INCOMING="/mnt/vm-share/incoming/ready"

inotifywait -m -e moved_to --format '%w%f' \
    "$INCOMING/movies" \
    "$INCOMING/shows" |
while read -r path; do
    # only process directories
    [[ -d "$path" ]] || continue

    /usr/local/bin/ingestion-host.sh "$path"
done

exit 0

#now add a systemd service
#save to: /etc/systemd/system/ingestion-host-watch.service

# [Unit]
# Description=Media ingestion watcher
# After=network.target

# [Service]
# ExecStart=/usr/local/bin/ingestion-host-watch.sh
# Restart=always
# RestartSec=2

# # Explicitly run as root (optional, but clear)
# User=root

# # Optional but recommended
# WorkingDirectory=/

# # Better logging behavior
# StandardOutput=journal
# StandardError=journal

# [Install]
# WantedBy=multi-user.target

# #################
# #run:
# sudo chmod +x /usr/local/bin/ingestion-host-watch.sh
# sudo systemctl daemon-reexec
# sudo systemctl daemon-reload
# sudo systemctl enable ingestion-host-watch.service
# sudo systemctl start ingestion-host-watch.service
# #check status:
# sudo systemctl status ingestion-host-watch.service #must say active