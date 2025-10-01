sudo chmod +x /usr/local/bin/egress-watchdog.sh
sudo tee /etc/systemd/system/egress-watchdog.service > /dev/null <<'SVC'
[Unit]
Description=Egress Watchdog (fail-closed)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/egress-watchdog.sh

[Install]
WantedBy=multi-user.target
SVC

sudo tee /etc/systemd/system/egress-watchdog.timer > /dev/null <<'TMR'
[Unit]
Description=Run egress-watchdog every 10s
[Timer]
OnUnitActiveSec=10s
AccuracySec=1s
[Install]
WantedBy=timers.target
TMR

sudo systemctl daemon-reload
sudo systemctl enable --now egress-watchdog.timer