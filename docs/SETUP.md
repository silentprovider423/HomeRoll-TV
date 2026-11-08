# Setup guide: Immich server for HomeRoll TV

HomeRoll TV is only the app. Your photos live on your own **Immich server**. If you already run Immich (for example for the HomeRoll iPhone app), skip to step 3.

## What you need

- A computer that runs all the time (NAS, mini PC, home server) with **Docker** and Docker Compose
- An Apple TV with tvOS 26 in the same network (or connected to it via VPN)

## 1. Set up Immich with Docker

Official guide: <https://docs.immich.app/install/docker-compose>

```bash
mkdir immich-app && cd immich-app
wget -O docker-compose.yml https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
wget -O .env https://github.com/immich-app/immich/releases/latest/download/example.env
# edit .env: UPLOAD_LOCATION (where your photos are stored) and DB_PASSWORD
docker compose up -d
```

HomeRoll TV is tested with Immich **v3.3.x**. Newer versions usually work, older ones may not.

Useful server settings for the TV (Immich web › Administration › Settings):

- **Machine Learning › Smart Search** on – the TV search uses it.
- **Video Transcoding** – the Apple TV plays H.264 and HEVC (`hvc1`). If some videos stay black, enable transcoding for unsupported codecs, or turn on *real-time transcoding*: the app then falls back to Immich's HLS stream.
- **Thumbnail settings** – the TV shows `preview` images (default 1440 px) in full screen and loads the full-size image afterwards. A larger preview size (e.g. 2160 px) looks sharper on a 4K TV.

## 2. Create your account

1. Open `http://<server-ip>:2283` in a browser.
2. The first user you create is the admin. Upload photos there, with the [Immich CLI](https://docs.immich.app/features/command-line-interface) or with the HomeRoll iPhone app.
3. Optional, recommended for the TV: **Account Settings › API Keys › New API Key** with read permissions only (`asset.read`, `asset.view`, `asset.download`, `album.read`, `memory.read`, `person.read`, `timeline.read`, `user.read` – and `asset.update` if you want to set favourites from the TV). You can sign in with that key instead of your password.

## 3. Make the server reachable from the Apple TV

| Where | Address in the app | Notes |
|---|---|---|
| Home network | `http://192.168.x.y:2283` | simplest; type `http://`, otherwise the app tries `https://` first |
| VPN (Tailscale, WireGuard on the router) | `http://100.x.y.z:2283` | Apple TV has no VPN app of its own; put the VPN on your router |
| Public with HTTPS (reverse proxy, Cloudflare Tunnel) | `https://photos.example.com` | needs a normal certificate (Let's Encrypt) |

tvOS blocks plain `http://` to public domain names – public addresses must use HTTPS. Self-signed and home-CA certificates only work if you build the app yourself with `Resources/HeimnetzCA.der`.

## 4. Install the app

See [README › Install](../README.md#install-without-a-mac). Short version: Apple TV apps can't be sideloaded with SideStore/AltStore; use Xcode on a Mac once.

## 5. First start

1. Open HomeRoll TV. Allow **local network** access when asked (needed for the server at home and for signing in with the iPhone).
2. **With the iPhone:** scan the QR code on the TV with the iPhone camera, enter the server address and your Immich email + password (or the API key), tap *Sign In*. No camera? Open the address shown on the TV in any browser in your network and type the six-digit code.
3. **On the TV:** choose *Enter on TV* and fill in server, email and password with the remote (tvOS also offers to type on a nearby iPhone).
4. The library loads; memories are built after the first full load.
5. Drag HomeRoll TV into the **top row** of the Home screen to see memories and featured photos in the Top Shelf.

## Troubleshooting

| Problem | Fix |
|---|---|
| "No Immich server answers at this address" | Check `http://` and port `2283`; open `http://<server>:2283/api/server/ping` in a browser – it must say `pong`. |
| QR page doesn't open on the iPhone | iPhone and Apple TV must be in the same network (no guest Wi-Fi). Some routers isolate Wi-Fi clients – sign in on the TV instead. |
| "Pairing not possible" on the TV | The Apple TV has no IPv4 address in the home network (e.g. only VPN). Sign in on the TV. |
| Videos stay black | Codec not supported by tvOS (VP9, AV1, `hev1`). Enable transcoding in Immich (step 1). |
| Top Shelf is empty | App must be in the top row; open the app once after signing in so it can save the previews. |
| Signed out after a while | The session was removed in Immich (Account Settings › Sessions). Sign in again or use an API key. |
