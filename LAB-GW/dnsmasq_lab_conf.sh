sudo tee /etc/dnsmasq.d/lab.conf > /dev/null <<'EOF'
listen-address=127.0.0.1,10.0.100.1
bind-interfaces
no-resolv
server=8.8.8.8
address=/login.cloud.example/203.0.113.45
cache-size=1000
EOF
sudo systemctl enable --now dnsmasq