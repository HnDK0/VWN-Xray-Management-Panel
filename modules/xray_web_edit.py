#!/usr/bin/env python3
# =================================================================
# xray_web_edit.py — Веб-редактирование параметров Xray
# Используется из web_panel.py
# =================================================================

import sys, json, subprocess, re, os

XRAY_CONFIG = "/usr/local/etc/xray/config.json"
NGINX_CONF = "/etc/nginx/conf.d/xray.conf"

def change_port(new_port):
    try:
        port = int(new_port)
        if port < 1024 or port > 65535:
            print("Error: port must be 1024-65535")
            return 1
    except ValueError:
        print("Error: invalid port number")
        return 1
    
    with open(XRAY_CONFIG) as f:
        cfg = json.load(f)
    
    old_port = cfg["inbounds"][0]["port"]
    cfg["inbounds"][0]["port"] = port
    
    with open(XRAY_CONFIG, "w") as f:
        json.dump(cfg, f, indent=2)
    
    # Обновляем nginx
    if os.path.exists(NGINX_CONF):
        with open(NGINX_CONF) as f:
            s = f.read()
        s = s.replace(f"127.0.0.1:{old_port}", f"127.0.0.1:{port}")
        with open(NGINX_CONF, "w") as f:
            f.write(s)
    
    print(f"Port changed from {old_port} to {port}")
    return 0

def change_path(new_path):
    if not new_path.startswith("/"):
        new_path = "/" + new_path
    
    with open(XRAY_CONFIG) as f:
        cfg = json.load(f)
    
    ss = cfg["inbounds"][0].get("streamSettings", {})
    ws = ss.get("wsSettings", {})
    xh = ss.get("xhttpSettings", {})
    
    old_path = ws.get("path") or xh.get("path") or ""
    
    if ws:
        ws["path"] = new_path
    if xh:
        xh["path"] = new_path
    
    with open(XRAY_CONFIG, "w") as f:
        json.dump(cfg, f, indent=2)
    
    print(f"Path changed from '{old_path}' to '{new_path}'")
    return 0

def change_domain(new_domain):
    with open(XRAY_CONFIG) as f:
        cfg = json.load(f)
    
    ss = cfg["inbounds"][0].get("streamSettings", {})
    ws = ss.get("wsSettings", {})
    xh = ss.get("xhttpSettings", {})
    
    old_domain = ws.get("host") or xh.get("host") or ""
    
    if ws:
        ws["host"] = new_domain
    if xh:
        xh["host"] = new_domain
    
    with open(XRAY_CONFIG, "w") as f:
        json.dump(cfg, f, indent=2)
    
    # Обновляем nginx
    if os.path.exists(NGINX_CONF):
        with open(NGINX_CONF) as f:
            s = f.read()
        s = re.sub(r"server_name\s+\S+;", f"server_name {new_domain};", s)
        with open(NGINX_CONF, "w") as f:
            f.write(s)
    
    print(f"Domain changed from '{old_domain}' to '{new_domain}'")
    return 0

def change_uuid():
    with open(XRAY_CONFIG) as f:
        cfg = json.load(f)
    
    new_uuid = subprocess.check_output(["cat", "/proc/sys/kernel/random/uuid"]).decode().strip()
    cfg["inbounds"][0]["settings"]["clients"][0]["id"] = new_uuid
    
    with open(XRAY_CONFIG, "w") as f:
        json.dump(cfg, f, indent=2)
    
    print(f"New UUID: {new_uuid}")
    return 0

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: xray_web_edit.py <port|path|domain|uuid> [value]")
        sys.exit(1)
    
    action = sys.argv[1]
    
    if action == "port" and len(sys.argv) > 2:
        sys.exit(change_port(sys.argv[2]))
    elif action == "path" and len(sys.argv) > 2:
        sys.exit(change_path(sys.argv[2]))
    elif action == "domain" and len(sys.argv) > 2:
        sys.exit(change_domain(sys.argv[2]))
    elif action == "uuid":
        sys.exit(change_uuid())
    else:
        print(f"Unknown action: {action}")
        sys.exit(1)