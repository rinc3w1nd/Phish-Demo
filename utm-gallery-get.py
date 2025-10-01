#!/usr/bin/env python3
"""
utm-gallery-get.py
Browse UTM Gallery, pick a VM, download the ZIP, and install into UTM.

Rules:
  - If --name is not provided: generate random two-word hyphenated name + timestamp
  - If --name is provided: use it exactly
  - If --copies N > 1: append -1, -2, … to each copy’s name
  - Renames .utm folder(s) and sets internal config.plist 'name'

Usage examples:
  ./utm-gallery-get.py
  ./utm-gallery-get.py --copies 3
  ./utm-gallery-get.py --name LAB-VICTIM --copies 2
"""

import sys, os, time, glob, shutil, zipfile, plistlib, random
from urllib.parse import urljoin, urlparse
import argparse
import requests
from bs4 import BeautifulSoup
from tqdm import tqdm

GALLERY_BASE = "https://mac.getutm.app/gallery/"
HEADERS = {"User-Agent": "utm-gallery-get/1.3 (+https://getutm.app)"}

ADJECTIVES = [
    "amber","arcane","brisk","cerulean","crimson","dapper","dusky","ember",
    "feral","fluid","gilded","glacial","jade","lunar","mint","nocturne",
    "opal","primal","quartz","rapid","scarlet","silken","silver","stealthy",
    "swift","vivid","zenith"
]
NOUNS = [
    "comet","cipher","falcon","harbor","horizon","kernel","lantern","matrix",
    "nebula","octave","onyx","packet","prairie","quasar","quill","raven",
    "relay","saber","sentinel","spire","synergy","talon","turbine","vertex",
    "willow","zephyr"
]

def rand_name():
    return f"{random.choice(ADJECTIVES)}-{random.choice(NOUNS)}"

def parse_args():
    ap = argparse.ArgumentParser(description="UTM Gallery downloader & installer")
    ap.add_argument("--name", help="Base VM name to set in UTM and folder")
    ap.add_argument("--copies", type=int, default=1, help="Number of installs to create (default 1)")
    ap.add_argument("--downloads", default=os.path.expanduser("~/Downloads"), help="Download dir")
    ap.add_argument("--utm-docs", default=os.path.expanduser("~/Library/Containers/com.utmapp.UTM/Data/Documents"),
                    help="UTM Documents dir")
    return ap.parse_args()

def fetch(url):
    r = requests.get(url, headers=HEADERS, timeout=20)
    r.raise_for_status()
    return r.text

def find_vm_pages(index_html):
    soup = BeautifulSoup(index_html, "html.parser")
    links = []
    for a in soup.find_all("a", href=True):
        href = a["href"]
        if "/gallery/" in href or href.strip("/").endswith((".html","/")):
            full = urljoin(GALLERY_BASE, href)
            if full.startswith(GALLERY_BASE):
                links.append(full)
    seen, out = set(), []
    for l in links:
        if l not in seen:
            seen.add(l); out.append(l)
    return out

def find_zip_for_page(page_html, page_url):
    soup = BeautifulSoup(page_html, "html.parser")
    return [urljoin(page_url, a["href"]) for a in soup.find_all("a", href=True) if a["href"].lower().endswith(".zip")]

def download_file(url, outpath):
    with requests.get(url, stream=True, headers=HEADERS, timeout=60) as r:
        r.raise_for_status()
        total = int(r.headers.get("Content-Length", 0))
        with open(outpath, "wb") as f, tqdm(
            total=total if total>0 else None,
            unit='B', unit_scale=True, desc=os.path.basename(outpath)
        ) as pbar:
            for chunk in r.iter_content(chunk_size=128*1024):
                if chunk:
                    f.write(chunk)
                    if total>0: pbar.update(len(chunk))
    return outpath

def extract_zip_to(zip_path, dest_dir):
    with zipfile.ZipFile(zip_path, 'r') as zf:
        zf.extractall(dest_dir)
    return sorted(glob.glob(os.path.join(dest_dir, "*.utm")), key=lambda p: os.path.getmtime(p), reverse=True)

def set_vm_display_name(utm_pkg_path, new_name):
    cfg = os.path.join(utm_pkg_path, "config.plist")
    if not os.path.isfile(cfg): return
    with open(cfg, "rb") as f:
        data = plistlib.load(f)
    data["name"] = new_name
    with open(cfg, "wb") as f:
        plistlib.dump(data, f)

def unique_path(path):
    if not os.path.exists(path):
        return path
    base, ext = os.path.splitext(path)
    i = 2
    while True:
        candidate = f"{base}-{i}{ext}"
        if not os.path.exists(candidate):
            return candidate
        i += 1

def main():
    args = parse_args()

    print("Fetching UTM gallery index…")
    idx_html = fetch(GALLERY_BASE)
    pages = find_vm_pages(idx_html)

    items = []
    for p in pages:
        try:
            html = fetch(p)
        except Exception:
            continue
        soup = BeautifulSoup(html, "html.parser")
        title = soup.find(["h1","h2"])
        title_text = title.get_text().strip() if title else p
        zips = find_zip_for_page(html, p)
        if zips:
            items.append({"title": title_text, "page": p, "zips": zips})

    if not items:
        print("No downloadable VMs found.")
        sys.exit(1)

    print("\nAvailable VMs:")
    for i, it in enumerate(items, start=1):
        print(f"{i:2d}. {it['title']}")
        for z in it['zips']:
            print(f"     → {z}")
    sel = input("\nEnter number to download (or q): ").strip().lower()
    if sel == 'q': sys.exit(0)
    choice = items[int(sel)-1]
    zipurl = choice['zips'][0]

    os.makedirs(args.downloads, exist_ok=True)
    outzip = os.path.join(args.downloads, os.path.basename(urlparse(zipurl).path))
    print(f"Downloading {zipurl} → {outzip}")
    download_file(zipurl, outzip)

    os.makedirs(args.utm_docs, exist_ok=True)
    print(f"Extracting into {args.utm_docs} …")
    before = set(glob.glob(os.path.join(args.utm_docs, "*.utm")))
    extract_zip_to(outzip, args.utm_docs)
    after = set(glob.glob(os.path.join(args.utm_docs, "*.utm")))
    created = sorted(list(after - before), key=lambda p: os.path.getmtime(p), reverse=True)
    if not created:
        print("No .utm package found after extraction.")
        sys.exit(1)

    # Naming rules
    if args.name:
        base_name = args.name
    else:
        base_name = f"{rand_name()}-{time.strftime('%Y%m%d-%H%M%S')}"

    src_pkg = created[0]
    installs = []
    for i in range(1, args.copies+1):
        vm_name = base_name if args.copies == 1 else f"{base_name}-{i}"
        dst_pkg = unique_path(os.path.join(args.utm_docs, f"{vm_name}.utm"))
        if i == 1:
            if os.path.abspath(src_pkg) != os.path.abspath(dst_pkg):
                shutil.move(src_pkg, dst_pkg)
        else:
            shutil.copytree(installs[0][0], dst_pkg)
        set_vm_display_name(dst_pkg, vm_name)
        installs.append((dst_pkg, vm_name))

    print("\nInstalled VM(s):")
    for pkg, name in installs:
        print(f"  {name} → {pkg}")

    print("\nDone. Restart UTM to see them.")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nAborted.")