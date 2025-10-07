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

import sys, os, time, glob, shutil, zipfile, plistlib, random, json
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

def default_utm_docs():
    candidates = [
        os.path.expanduser("~/Library/Group Containers/group.com.utmapp.UTM/Documents"),
        os.path.expanduser("~/Library/Containers/com.utmapp.UTM/Data/Documents"),
    ]
    for path in candidates:
        if os.path.isdir(path):
            return path
    return candidates[-1]


def parse_args():
    ap = argparse.ArgumentParser(description="UTM Gallery downloader & installer")
    ap.add_argument("--name", help="Base VM name to set in UTM and folder")
    ap.add_argument("--copies", type=int, default=1, help="Number of installs to create (default 1)")
    ap.add_argument("--downloads", default=os.path.expanduser("~/Downloads"), help="Download dir")
    ap.add_argument("--utm-docs", default=default_utm_docs(),
                    help="UTM Documents dir (App Store or direct-download)")
    return ap.parse_args()

def fetch(url):
    r = requests.get(url, headers=HEADERS, timeout=20)
    r.raise_for_status()
    return r.text

def gather_zip_links(node):
    links = []
    if isinstance(node, str):
        if node.lower().endswith(".zip"):
            links.append(node)
    elif isinstance(node, dict):
        for v in node.values():
            links.extend(gather_zip_links(v))
    elif isinstance(node, (list, tuple, set)):
        for item in node:
            links.extend(gather_zip_links(item))
    return links


def extract_from_next_data(index_html):
    """Parse Next.js hydration data when available to enumerate gallery items."""
    soup = BeautifulSoup(index_html, "html.parser")
    script = soup.find("script", id="__NEXT_DATA__")
    if not script or not script.string:
        return []

    try:
        data = json.loads(script.string)
    except json.JSONDecodeError:
        return []

    items = {}

    def visit(node):
        if isinstance(node, dict):
            slug = node.get("path") or node.get("url") or node.get("slug")
            zips = gather_zip_links(node.get("downloads")) if "downloads" in node else []
            if not zips:
                for key in ("downloadUrl", "downloadURL", "directLink", "file", "files"):
                    if key in node:
                        zips.extend(gather_zip_links(node[key]))

            if slug and zips:
                if isinstance(slug, str):
                    page = slug if slug.startswith("http") else urljoin(GALLERY_BASE, slug.lstrip("/"))
                else:
                    page = None
                if page and page.startswith(GALLERY_BASE):
                    title = node.get("title") or node.get("name") or os.path.basename(urlparse(page).path)
                    norm_page = page.rstrip("/")
                    existing = items.get(norm_page)
                    if existing:
                        existing["zips"].extend(zips)
                    else:
                        items[norm_page] = {"title": title, "page": page, "zips": list(zips)}

            for value in node.values():
                visit(value)
        elif isinstance(node, (list, tuple, set)):
            for value in node:
                visit(value)

    visit(data)

    # Deduplicate and normalize zip URLs
    normalized = []
    for item in items.values():
        unique_zips = []
        seen = set()
        for link in item["zips"]:
            resolved = urljoin(item["page"], link) if not urlparse(link).scheme else link
            if resolved not in seen:
                seen.add(resolved)
                unique_zips.append(resolved)
        item["zips"] = unique_zips
        normalized.append(item)
    return normalized


def find_vm_pages(index_html):
    """Return gallery entries discovered on the landing page."""
    # Prefer structured data embedded in the page when available.
    items = extract_from_next_data(index_html)
    if items:
        return items

    # Fallback to scraping anchor tags when the structured data is unavailable.
    soup = BeautifulSoup(index_html, "html.parser")
    links = []
    for a in soup.find_all("a", href=True):
        href = a["href"]
        if "/gallery/" in href or href.strip("/").endswith((".html", "/")):
            full = urljoin(GALLERY_BASE, href)
            if full.startswith(GALLERY_BASE):
                links.append(full)
    seen, out = set(), []
    for link in links:
        if link not in seen:
            seen.add(link)
            out.append({"title": link, "page": link, "zips": []})
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
    discovered = find_vm_pages(idx_html)

    items = []
    for entry in discovered:
        if isinstance(entry, dict):
            page_url = entry.get("page") or entry.get("url")
            title_hint = entry.get("title")
            zips = list(entry.get("zips", []))
        else:
            page_url = entry
            title_hint = None
            zips = []

        if not page_url:
            continue

        if not urlparse(page_url).scheme:
            page_url = urljoin(GALLERY_BASE, page_url.lstrip("/"))

        page_html = None
        if not zips:
            try:
                page_html = fetch(page_url)
            except Exception:
                continue
            zips = find_zip_for_page(page_html, page_url)

        if not zips:
            continue

        title_text = title_hint
        if title_text is None:
            if page_html is None:
                try:
                    page_html = fetch(page_url)
                except Exception:
                    page_html = ""
            soup = BeautifulSoup(page_html, "html.parser") if page_html else None
            title = None
            if soup:
                title = soup.find(["h1", "h2"])
            title_text = title.get_text().strip() if title else page_url

        items.append({"title": title_text, "page": page_url, "zips": zips})

    if not items:
        print("No downloadable VMs found.")
        sys.exit(1)

    # Deduplicate by page URL in case multiple sources returned the same entry.
    deduped = []
    seen_pages = set()
    for item in items:
        page_key = item["page"].rstrip("/")
        if page_key not in seen_pages:
            seen_pages.add(page_key)
            deduped.append(item)

    if not deduped:
        print("No downloadable VMs found.")
        sys.exit(1)

    print("\nAvailable VMs:")
    for i, it in enumerate(deduped, start=1):
        print(f"{i:2d}. {it['title']}")
        for z in it['zips']:
            print(f"     → {z}")
    sel = input("\nEnter number to download (or q): ").strip().lower()
    if sel == 'q': sys.exit(0)
    choice = deduped[int(sel)-1]
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