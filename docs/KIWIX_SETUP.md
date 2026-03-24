# Kiwix Setup Guide

Kiwix serves offline copies of Wikipedia, Stack Overflow, and other knowledge
bases from compressed ZIM files. It provides full-text search and an HTTP
interface for both human browsing and RAG ingestion.

## Install kiwix-tools

kiwix-tools includes `kiwix-serve` (HTTP server) and `kiwix-manage` (library
management). Install the one that matches your distro:

```bash
# Arch Linux
sudo pacman -S kiwix-tools

# Ubuntu / Debian
sudo apt install kiwix-tools

# Fedora
sudo dnf install kiwix-tools

# Or use the standalone binary from GitHub releases:
# https://github.com/kiwix/kiwix-tools/releases
```

## Download ZIM Files

Check current file sizes and download links at https://library.kiwix.org.
Sizes shift with each monthly release.

### Recommended initial set (~164 GB)

| ZIM File | Approx Size | Why |
|---|---|---|
| `wikipedia_en_all_maxi` | ~97 GB | Full English Wikipedia with images |
| `stackoverflow.com_en_all` | ~55 GB | Programming Q&A |
| `stackexchange_unix` | ~5 GB | Linux/shell expertise |
| `stackexchange_superuser` | ~3 GB | Hardware/OS troubleshooting |
| `stackexchange_serverfault` | ~3 GB | Sysadmin knowledge |
| `stackexchange_ai` | ~1 GB | AI/ML Q&A |

### Download commands

```bash
# Downloads resume with -c if interrupted.
# Replace YYYY-MM with the current date from library.kiwix.org.

wget -c -P /knowledge/zim/ \
  "https://download.kiwix.org/zim/wikipedia/wikipedia_en_all_maxi_YYYY-MM.zim"

wget -c -P /knowledge/zim/ \
  "https://download.kiwix.org/zim/stack_exchange/stackoverflow.com_en_all_YYYY-MM.zim"

# Repeat for each ZIM file.
```

Wikipedia is ~97 GB — expect several hours even on a fast connection. The
`-c` flag lets you stop and resume.

### Later additions (when you want more)

| ZIM File | Size | Notes |
|---|---|---|
| `gutenberg_en_all` | ~60 GB | 70k+ public domain books |
| `wiktionary_en_all` | ~8 GB | Dictionary/definitions |
| `stackexchange_datascience` | ~2 GB | Data science Q&A |
| `devdocs_en_all` | ~1 GB | Developer documentation aggregator |
| `wikipedia_en_all_nopic` | ~22 GB | Wikipedia without images (smaller) |

## Build the Library and Start Serving

kiwix-serve reads a library XML file that indexes your ZIM files. You must
build this with `kiwix-manage` first.

```bash
# Register each ZIM in the library
for zim in /knowledge/zim/*.zim; do
    kiwix-manage /knowledge/kiwix-library.xml add "$zim"
done

# Start the server
kiwix-serve --library /knowledge/kiwix-library.xml --port 8888
```

Browse to http://localhost:8888 to verify.

## Run as a systemd Service

Create `/etc/systemd/system/kiwix-serve.service`:

```ini
[Unit]
Description=Kiwix Local Knowledge Server
After=local-fs.target

[Service]
ExecStart=/usr/bin/kiwix-serve --library /knowledge/kiwix-library.xml --port 8888 --nodatealias
Restart=on-failure
RestartSec=5
User=matt

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now kiwix-serve
sudo systemctl status kiwix-serve
```

The `After=local-fs.target` ensures the knowledge drive is mounted before
kiwix-serve tries to read its library.

## Kiwix API for RAG Ingestion

kiwix-serve exposes endpoints the RAG pipeline uses to fetch article content.

### Search for articles
```
GET http://localhost:8888/search?pattern=python+decorators&books=stackoverflow&pageLength=10
```
Returns an HTML results page. Parse with BeautifulSoup to extract article URLs.

### Fetch article content
```
GET http://localhost:8888/wikipedia/A/Python_(programming_language)
```
Returns the full article as HTML. Strip tags to get plain text for embedding.

### OPDS catalog (structured metadata)
```
GET http://localhost:8888/catalog/v2/entries
```
Returns an OPDS feed (XML/JSON) listing available content.

### Suggestion API (autocomplete)
```
GET http://localhost:8888/suggest?term=bitnet&limit=10
```
Returns JSON suggestions for partial search terms.

The RAG ingestion script in `docs/RAG_PIPELINE.md` uses the search + fetch
pattern to crawl articles for embedding.

## Notes

- ZIM files are read-only compressed archives — no extraction needed
- Adding a new ZIM: download it, run `kiwix-manage ... add`, restart the service
- The `_maxi` Wikipedia variant includes images; `_nopic` saves ~75 GB
- kiwix-serve is single-threaded per request but handles concurrent connections
- On the 10900K with 32GB RAM, serving multiple ZIMs simultaneously is no problem
