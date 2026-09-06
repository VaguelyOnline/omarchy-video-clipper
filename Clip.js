.pragma library

// Accepts SS, MM:SS or HH:MM:SS, with an optional fractional part.
// Returns the value in seconds, or -1 when the text is not a timestamp.
function parseTime(text) {
  var raw = String(text === undefined || text === null ? "" : text).trim()
  if (raw === "") return -1
  if (!/^\d{1,3}(:\d{1,2}){0,2}(\.\d{1,3})?$/.test(raw)) return -1
  var parts = raw.split(":")
  var total = 0
  for (var i = 0; i < parts.length; i++) {
    var part = parseFloat(parts[i])
    if (isNaN(part)) return -1
    if (i > 0 && part >= 60) return -1
    total = total * 60 + part
  }
  return total
}

function formatTime(seconds) {
  var value = Number(seconds)
  if (!isFinite(value) || value < 0) value = 0
  var whole = Math.floor(value)
  var h = Math.floor(whole / 3600)
  var m = Math.floor((whole % 3600) / 60)
  var s = whole % 60
  var mm = (m < 10 ? "0" : "") + m
  var ss = (s < 10 ? "0" : "") + s
  return h > 0 ? h + ":" + mm + ":" + ss : mm + ":" + ss
}

function formatBytes(bytes) {
  var value = Number(bytes)
  if (!isFinite(value) || value <= 0) return ""
  var units = ["B", "KB", "MB", "GB", "TB"]
  var unit = 0
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024
    unit++
  }
  return (value >= 100 || unit === 0 ? Math.round(value) : value.toFixed(1)) + " " + units[unit]
}

function formatSpeed(bytesPerSecond) {
  var text = formatBytes(bytesPerSecond)
  return text === "" ? "" : text + "/s"
}

function formatEta(seconds) {
  var value = Number(seconds)
  if (!isFinite(value) || value <= 0) return ""
  return formatTime(value) + " left"
}

// A job's segments are carried through the queue model as JSON, because
// ListModel roles only hold flat values.
function decodeSegments(json) {
  try {
    var parsed = JSON.parse(String(json || "[]"))
    return parsed instanceof Array ? parsed : []
  } catch (e) {
    return []
  }
}

function segmentLabel(segment) {
  if (!segment) return ""
  var start = formatTime(segment.start)
  return segment.end === null || segment.end === undefined || segment.end < 0
    ? start + " → end"
    : start + " → " + formatTime(segment.end)
}

function segmentsSummary(segments) {
  if (!segments || segments.length === 0) return "Whole video"
  if (segments.length === 1) return segmentLabel(segments[0])
  return segments.length + " segments · " + totalSegmentText(segments)
}

function totalSegmentSeconds(segments) {
  var total = 0
  for (var i = 0; i < segments.length; i++) {
    var segment = segments[i]
    if (!segment || segment.end === null || segment.end === undefined || segment.end < 0) return -1
    total += Math.max(0, segment.end - segment.start)
  }
  return total
}

function totalSegmentText(segments) {
  var total = totalSegmentSeconds(segments)
  return total < 0 ? "open ended" : formatTime(total)
}

// Turn a segment list into the --section arguments the worker expects:
// start and end in seconds, an empty end meaning "run to the end".
function sectionArguments(segments) {
  var args = []
  for (var i = 0; i < segments.length; i++) {
    var segment = segments[i]
    var end = segment.end === null || segment.end === undefined || segment.end < 0 ? "" : String(segment.end)
    args.push(String(segment.start) + "-" + end)
  }
  return args
}

// Where the download has reached inside the source video, so the panel can say
// "01:40" rather than only "62%". Byte progress is a proxy for time progress,
// so this is an estimate, not a seek position.
function positionSeconds(segments, segmentIndex, fraction, duration) {
  var ratio = Math.max(0, Math.min(1, Number(fraction) || 0))
  if (!segments || segments.length === 0) {
    var total = Number(duration) || 0
    return total > 0 ? total * ratio : -1
  }
  var segment = segments[Math.max(0, Math.min(segmentIndex, segments.length - 1))]
  if (!segment) return -1
  var start = Number(segment.start) || 0
  var end = segment.end === null || segment.end === undefined || segment.end < 0
    ? Number(duration) || -1
    : Number(segment.end)
  if (end <= start) return start
  return start + (end - start) * ratio
}

function shortenUrl(url) {
  var text = String(url || "").replace(/^https?:\/\//, "").replace(/^www\./, "")
  return text.length > 46 ? text.slice(0, 45) + "…" : text
}

function isProbablyUrl(text) {
  return /^(https?:\/\/|www\.)\S+$/i.test(String(text || "").trim())
}
