import json, os, sys, urllib.request, urllib.parse

BASE = "http://jellyfin.jellyfin.svc.cluster.local:8096"
PW = os.environ["JF_PW"]

AUTH_HDR = ('MediaBrowser Client="media-hooks", Device="setup-script", '
            'DeviceId="media-hooks-setup", Version="1.0.0"')

def req(method, path, data=None, token=None):
    url = BASE + path
    headers = {"Content-Type": "application/json", "X-Emby-Authorization": AUTH_HDR}
    if token:
        headers["X-Emby-Token"] = token
    body = json.dumps(data).encode() if data is not None else None
    r = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:200]

def step(desc, *a, **k):
    s, b = req(*a, **k)
    print("  [%s] %s" % (s, desc))
    return s, b

# --- Skip wizard if already completed ---
s, info = req("GET", "/System/Info/Public")
already = isinstance(info, dict) and info.get("StartupWizardCompleted")
if already:
    print("  wizard already completed, skipping to auth")

# --- First-run wizard ---
if not already:
    step("startup config", "POST", "/Startup/Configuration",
         {"UICulture": "en-US", "MetadataCountryCode": "GB", "PreferredMetadataLanguage": "en"})
    step("get startup user", "GET", "/Startup/User")
    step("create admin user", "POST", "/Startup/User", {"Name": "admin", "Password": PW})
    step("remote access", "POST", "/Startup/RemoteAccess",
         {"EnableRemoteAccess": True, "EnableAutomaticPortMapping": False})
    step("complete wizard", "POST", "/Startup/Complete")

# --- Authenticate ---
s, auth = req("POST", "/Users/AuthenticateByName", {"Username": "admin", "Pw": PW})
if s != 200:
    print("AUTH FAILED", s, auth); sys.exit(1)
token = auth["AccessToken"]
print("  authenticated")

# --- Libraries (same host dirs Plex reads, mounted read-only at /media/*) ---
libs = [
    ("Anime",         "tvshows",    "/media/Anime"),
    ("TV",            "tvshows",    "/media/TVSeries"),
    ("Films",         "movies",     "/media/Movies"),
    ("Anime Films",   "movies",     "/media/AnimeFilms"),
    ("Documentaries", "movies",     "/media/Documentaries"),
    ("Short Films",   "movies",     "/media/ShortFilms"),
    ("Music",         "music",      "/media/Music"),
    ("Home Media",    "homevideos", "/media/HomeMedia"),
]
for name, ctype, path in libs:
    q = urllib.parse.urlencode({"name": name, "collectionType": ctype, "refreshLibrary": "false"})
    step("library %s -> %s" % (name, path), "POST", "/Library/VirtualFolders?" + q,
         {"LibraryOptions": {"PathInfos": [{"Path": path}]}}, token=token)

# --- Hardware transcoding (NVENC/NVDEC on the 4070) ---
s, enc = req("GET", "/System/Configuration/encoding", token=token)
if isinstance(enc, dict):
    enc["HardwareAccelerationType"] = "nvenc"
    enc["EnableHardwareEncoding"] = True
    enc["HardwareDecodingCodecs"] = ["h264", "hevc", "mpeg2video", "vc1", "vp9", "av1"]
    enc["EnableDecodingColorDepth10Hevc"] = True
    enc["EnableDecodingColorDepth10Vp9"] = True
    enc["EnableTonemapping"] = True
    step("enable NVENC", "POST", "/System/Configuration/encoding", enc, token=token)
else:
    print("  [warn] could not read encoding config:", enc)

# --- API key for media-hooks ---
step("create api key", "POST", "/Auth/Keys?app=media-hooks", token=token)
s, keys = req("GET", "/Auth/Keys", token=token)
apikey = ""
if isinstance(keys, dict):
    for k in keys.get("Items", []):
        if k.get("AppName") == "media-hooks":
            apikey = k.get("AccessToken", "")
if apikey:
    print("APIKEY=" + apikey)
else:
    print("APIKEY_MISSING", keys)
