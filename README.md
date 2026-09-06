# Video Clipper

A bar widget for downloading a video with `yt-dlp` — either the whole thing, or
any number of time segments that are stitched back into a single file.

Click the scissors in the bar to open the panel. The URL field takes focus, so
paste and go.

## What it does

- **Whole video** — one `yt-dlp` run, saved under the chosen folder.
- **Pick segments** — one `--download-sections "*start-end"` run per segment,
  then a single `ffmpeg` concat into one MP4. Segments are downloaded in the
  order listed and joined in that order.
- Timestamps are written as `SS`, `MM:SS` or `HH:MM:SS`. Leave an end blank to
  run to the end of the video.
- Jobs **queue**: add as many as you like, they run one at a time so they are
  not fighting for bandwidth. Each row can be cancelled, retried, or removed.
- Progress reports which segment is downloading and the point in the source
  video it has reached. Section downloads go through `ffmpeg`, which reports its
  exact write position, so that timestamp is real rather than inferred from
  bytes.
- **Open folder** on a finished job (or the folder button next to *Save to*)
  opens the directory with `xdg-open`.
- Nothing is written to disk but the finished video. The queue lives in memory
  for the life of the shell session; there is no history file.
- The completion notification is deliberately generic — "Download finished",
  with no file name. Omarchy keeps the newest notifications as JSON files under
  `~/.local/state/omarchy/notifications/history/`, so naming the file there
  would put a record of it on disk. Turn the notification off entirely with
  `"notifyOnComplete": false`.

## Joining segments

The worker first tries a stream copy, which is instant. If the pieces will not
copy into one container — a WebM segment beside an MP4 one, or two different
resolutions — it falls back to ffmpeg's concat *filter*, normalising resolution,
frame rate and audio layout before re-encoding to H.264/AAC. Segments with no
audio track get matching silence so the join does not fail.

Keeping **Prefer H.264 / AAC** on (the default) means the fast path is taken
almost every time.

## Advanced options

| Option | Default | What it does |
|--------|---------|--------------|
| Max quality | Best available | Caps the height passed to the `yt-dlp` format selector |
| Container | MP4 | Final container for the joined file |
| Cookies from | No cookies | `--cookies-from-browser`, for sites that need a login |
| Parallel fragments | 4 | `--concurrent-fragments` |
| File name | blank | Overrides the video title; the extension is added |
| Accurate cuts | on | `--force-keyframes-at-cuts` — slower, but clips start on time |
| Prefer H.264 / AAC | on | Picks codecs that stitch without a re-encode |
| Always produce the chosen container | on | Remux when the site hands back something else |
| Audio only | off | Saves an `m4a` |

Defaults come from the widget's entry in `~/.config/omarchy/shell.json`, so a
folder or quality you always want can be set once:

```json
{ "id": "vaguely.video-clipper", "outputDir": "~/Videos/clips", "quality": "1080" }
```

Every key in the manifest's `barWidget.defaults` can be set this way, plus
`notifyOnComplete` for the desktop notification when a job finishes.

## Pieces

| File | Role |
|------|------|
| `Panel.qml` | Bar button and the panel — entry point for `bar-widget` |
| `Service.qml` | The queue: one instance per shell session, runs jobs in turn |
| `Clip.js` | Timestamp parsing and formatting |
| `bin/video-clipper` | The worker: yt-dlp, the join, cleanup, and progress events |

The worker is a normal script and can be run on its own:

```bash
bin/video-clipper --url URL --outdir ~/Videos --section 90-165 --section 300-330
```

It writes one JSON event per line, each prefixed with `@@CLIP@@`, which is what
the panel reads.

## Requires

`yt-dlp`, `ffmpeg` and `ffprobe`, all of which Omarchy already installs.
`wl-clipboard` for the paste button.

## Note

The shell re-instantiates bar widgets at startup, so after editing these files
run `omarchy restart shell` to see the change.
