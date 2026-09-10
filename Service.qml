import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Clip.js" as Clip

// The download queue. Mounted once per shell session (kind: "service"), so the
// bar widget on every monitor talks to the same queue instead of each screen
// keeping its own. Nothing here is written to disk: the queue lives in memory
// for the life of the shell and disappears with it.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string scriptPath: String(Qt.resolvedUrl("bin/video-clipper")).replace(/^file:\/\//, "")

  property int nextJobId: 1
  property int runningJobId: -1
  property int pendingCancelId: -1
  property bool sawTerminalEvent: false
  property bool notifyOnComplete: true

  readonly property alias queue: queueModel

  // Site logins, keyed by job id. Kept out of the queue model so nothing that
  // renders the queue can read a password, and handed to the worker over stdin
  // so it never reaches argv. Forgotten once the job succeeds or is removed.
  property var credentials: ({})

  // Rolled up for the bar button: how much is outstanding and how far the
  // current download has got.
  property int activeCount: 0
  property int failedCount: 0
  property real activePercent: 0
  property string activeSummary: ""

  signal jobCompleted(string name, string dir)

  ListModel { id: queueModel }

  function indexOfJob(jobId) {
    for (var i = 0; i < queueModel.count; i++)
      if (queueModel.get(i).jobId === jobId) return i
    return -1
  }

  function isTerminal(state) {
    return state === "done" || state === "error" || state === "cancelled"
  }

  function refreshSummary() {
    var active = 0
    var failed = 0
    for (var i = 0; i < queueModel.count; i++) {
      var job = queueModel.get(i)
      if (job.state === "queued" || job.state === "running") active++
      if (job.state === "error") failed++
    }
    activeCount = active
    failedCount = failed

    var index = indexOfJob(runningJobId)
    if (index < 0) {
      activePercent = 0
      activeSummary = active > 0 ? active + " queued" : ""
      return
    }
    var current = queueModel.get(index)
    activePercent = current.percent
    activeSummary = current.title !== "" ? current.title : Clip.shortenUrl(current.url)
  }

  // spec: { url, segments[], outputDir, quality, container, filename, cookies,
  //         concurrent, audioOnly, preferH264, accurateCuts, forceContainer,
  //         username, password }
  function enqueue(spec) {
    var segments = spec.segments instanceof Array ? spec.segments : []
    var jobId = nextJobId++
    var username = String(spec.username || "")
    var password = String(spec.password || "")
    var hasLogin = username !== "" && password !== ""
    if (hasLogin) credentials[jobId] = { username: username, password: password }

    queueModel.append({
      jobId: jobId,
      url: String(spec.url || ""),
      title: "",
      segmentsJson: JSON.stringify(segments),
      outputDir: String(spec.outputDir || ""),
      quality: String(spec.quality || "best"),
      container: String(spec.container || "mp4"),
      filename: String(spec.filename || ""),
      cookies: String(spec.cookies || "none"),
      concurrent: Number(spec.concurrent) || 4,
      audioOnly: spec.audioOnly === true,
      preferH264: spec.preferH264 !== false,
      accurateCuts: spec.accurateCuts !== false,
      forceContainer: spec.forceContainer !== false,
      hasLogin: hasLogin,
      state: "queued",
      stage: "",
      detail: "",
      logLine: "",
      percent: 0,
      speed: "",
      eta: "",
      segIndex: 0,
      segTotal: segments.length > 0 ? segments.length : 1,
      positionText: "",
      duration: 0,
      outputPath: "",
      outputName: "",
      error: ""
    })
    refreshSummary()
    pump()
    return jobId
  }

  function forgetCredentials(jobId) {
    delete credentials[jobId]
  }

  function pump() {
    if (runner.running || runningJobId >= 0) return
    for (var i = 0; i < queueModel.count; i++) {
      if (queueModel.get(i).state !== "queued") continue
      start(i)
      return
    }
  }

  function start(index) {
    var job = queueModel.get(index)
    queueModel.setProperty(index, "state", "running")
    queueModel.setProperty(index, "stage", "probe")
    runningJobId = job.jobId
    sawTerminalEvent = false
    var login = job.hasLogin ? credentials[job.jobId] : null
    runner.login = login ? login.username + "\n" + login.password + "\n" : ""
    runner.command = buildArguments(job)
    runner.running = true
    refreshSummary()
  }

  function buildArguments(job) {
    var argv = [
      scriptPath,
      "--url", job.url,
      "--outdir", job.outputDir,
      "--quality", job.quality,
      "--container", job.container,
      "--concurrent", String(job.concurrent),
      "--cookies-from", job.cookies,
      job.preferH264 ? "--prefer-h264" : "--no-prefer-h264",
      job.accurateCuts ? "--accurate-cuts" : "--no-accurate-cuts",
      job.forceContainer ? "--force-container" : "--no-force-container"
    ]
    if (job.audioOnly) argv.push("--audio-only")
    if (job.filename !== "") argv.push("--filename", job.filename)
    if (job.hasLogin) argv.push("--login-stdin")

    var sections = Clip.sectionArguments(Clip.decodeSegments(job.segmentsJson))
    for (var i = 0; i < sections.length; i++) argv.push("--section", sections[i])
    return argv
  }

  function cancel(jobId) {
    var index = indexOfJob(jobId)
    if (index < 0) return
    if (queueModel.get(index).state === "running") {
      pendingCancelId = jobId
      runner.running = false
      return
    }
    if (queueModel.get(index).state === "queued") {
      queueModel.setProperty(index, "state", "cancelled")
      refreshSummary()
    }
  }

  function removeJob(jobId) {
    var index = indexOfJob(jobId)
    if (index < 0) return
    if (queueModel.get(index).state === "running") {
      pendingCancelId = jobId
      runner.running = false
      return
    }
    forgetCredentials(jobId)
    queueModel.remove(index)
    refreshSummary()
  }

  function clearFinished() {
    for (var i = queueModel.count - 1; i >= 0; i--) {
      var job = queueModel.get(i)
      if (!isTerminal(job.state)) continue
      forgetCredentials(job.jobId)
      queueModel.remove(i)
    }
    refreshSummary()
  }

  function retry(jobId) {
    var index = indexOfJob(jobId)
    if (index < 0) return
    queueModel.setProperty(index, "state", "queued")
    queueModel.setProperty(index, "error", "")
    queueModel.setProperty(index, "percent", 0)
    queueModel.setProperty(index, "stage", "")
    queueModel.setProperty(index, "outputPath", "")
    refreshSummary()
    pump()
  }

  function openDirectory(dir) {
    if (!dir) return
    Util.execArgv(["xdg-open", String(dir)])
  }

  function openFile(path) {
    if (!path) return
    Util.execArgv(["xdg-open", String(path)])
  }

  // Deliberately says nothing about what was downloaded. Omarchy persists the
  // newest notifications as one JSON file each under
  // ~/.local/state/omarchy/notifications/history/, so naming the file here
  // would leave a record of it on disk — the history this plugin otherwise
  // takes care not to keep. The finished job is named in the panel instead,
  // which lives only in memory.
  function notify(title) {
    Util.execArgv(["notify-send", "-a", "Video Clipper", String(title)])
  }

  // ------------------------------------------------------------- events

  function numberOr(value, fallback) {
    var parsed = Number(value)
    return isFinite(parsed) ? parsed : fallback
  }

  function handleEvent(event) {
    var index = indexOfJob(runningJobId)
    if (index < 0) return
    var job = queueModel.get(index)

    switch (event.type) {
    case "info":
      if (event.title) queueModel.setProperty(index, "title", String(event.title))
      queueModel.setProperty(index, "duration", numberOr(event.duration, 0))
      break

    case "stage":
      queueModel.setProperty(index, "stage", String(event.stage || ""))
      queueModel.setProperty(index, "detail", String(event.detail || ""))
      if (event.stage === "merge" || event.stage === "encode")
        queueModel.setProperty(index, "percent", 0)
      break

    case "segment":
      queueModel.setProperty(index, "segIndex", numberOr(event.index, 1))
      queueModel.setProperty(index, "segTotal", numberOr(event.total, 1))
      queueModel.setProperty(index, "percent", 0)
      queueModel.setProperty(index, "positionText", "")
      break

    case "progress":
      applyProgress(index, job, event)
      break

    case "segtime":
      applySegmentTime(index, job, numberOr(event.seconds, -1))
      break

    case "merge":
      var seconds = numberOr(event.seconds, 0)
      var span = numberOr(event.total, 0)
      if (span > 0) queueModel.setProperty(index, "percent", Math.min(100, seconds / span * 100))
      queueModel.setProperty(index, "positionText", Clip.formatTime(seconds))
      break

    case "log":
      queueModel.setProperty(index, "logLine", String(event.line || ""))
      break

    case "done":
      sawTerminalEvent = true
      queueModel.setProperty(index, "state", "done")
      queueModel.setProperty(index, "stage", "")
      queueModel.setProperty(index, "percent", 100)
      queueModel.setProperty(index, "outputPath", String(event.path || ""))
      queueModel.setProperty(index, "outputName", String(event.name || ""))
      forgetCredentials(job.jobId)
      if (notifyOnComplete) notify("Download finished")
      jobCompleted(String(event.name || ""), String(event.dir || ""))
      break

    case "error":
      sawTerminalEvent = true
      queueModel.setProperty(index, "state", "error")
      queueModel.setProperty(index, "stage", "")
      queueModel.setProperty(index, "error", String(event.message || "Download failed"))
      break

    case "cancelled":
      sawTerminalEvent = true
      queueModel.setProperty(index, "state", "cancelled")
      queueModel.setProperty(index, "stage", "")
      break
    }
    refreshSummary()
  }

  // Section downloads run through ffmpeg, which reports the exact point in the
  // video it has written rather than a byte count — so the position shown is
  // real, not inferred.
  function applySegmentTime(index, job, seconds) {
    if (seconds < 0) return

    var segments = Clip.decodeSegments(job.segmentsJson)
    var start = 0
    var span = -1

    if (segments.length > 0) {
      var segment = segments[Math.max(0, Math.min(job.segIndex - 1, segments.length - 1))]
      start = Number(segment.start) || 0
      var end = segment.end === null || segment.end === undefined || segment.end < 0
        ? (job.duration > 0 ? job.duration : -1)
        : Number(segment.end)
      if (end > start) span = end - start
    } else if (job.duration > 0) {
      span = job.duration
    }

    if (span > 0) queueModel.setProperty(index, "percent", Math.min(100, seconds / span * 100))
    queueModel.setProperty(index, "positionText", Clip.formatTime(start + seconds))
    queueModel.setProperty(index, "stage", "download")
  }

  function applyProgress(index, job, event) {
    var downloaded = numberOr(event.downloaded, -1)
    var total = numberOr(event.total, -1)
    var fraction = total > 0 && downloaded >= 0 ? Math.min(1, downloaded / total) : -1

    if (fraction >= 0) queueModel.setProperty(index, "percent", fraction * 100)
    queueModel.setProperty(index, "speed", Clip.formatSpeed(event.speed))
    queueModel.setProperty(index, "eta", Clip.formatEta(event.eta))
    queueModel.setProperty(index, "stage", "download")

    if (fraction >= 0) {
      var segments = Clip.decodeSegments(job.segmentsJson)
      var position = Clip.positionSeconds(segments, Math.max(0, job.segIndex - 1), fraction, job.duration)
      queueModel.setProperty(index, "positionText", position >= 0 ? Clip.formatTime(position) : "")
    }
  }

  function handleLine(line) {
    var text = String(line || "")
    if (text.indexOf("@@CLIP@@") !== 0) return
    var event = null
    try {
      event = JSON.parse(text.substring(8))
    } catch (error) {
      return
    }
    if (event && event.type) handleEvent(event)
  }

  function finishRun(exitCode) {
    var index = indexOfJob(runningJobId)
    if (index >= 0 && !isTerminal(queueModel.get(index).state)) {
      // The worker died without reporting why — a cancel that beat its own
      // event, or a crash. Say which, rather than leaving the row spinning.
      if (pendingCancelId === runningJobId || exitCode === 130 || exitCode === 143)
        queueModel.setProperty(index, "state", "cancelled")
      else {
        queueModel.setProperty(index, "state", "error")
        queueModel.setProperty(index, "error", "The download worker stopped unexpectedly (exit " + exitCode + ")")
      }
      queueModel.setProperty(index, "stage", "")
    }
    pendingCancelId = -1
    runningJobId = -1
    refreshSummary()
    Qt.callLater(pump)
  }

  Process {
    id: runner
    // "username\npassword\n" for a job with a login, else empty. Written once
    // the worker is up (it reads it for --login-stdin) and dropped straight
    // after, so it does not outlive the hand-off.
    property string login: ""
    stdinEnabled: true
    onStarted: {
      if (login !== "") write(login)
      login = ""
    }
    stdout: SplitParser { onRead: function(line) { root.handleLine(line) } }
    stderr: SplitParser { onRead: function(line) { root.handleLine(line) } }
    onExited: function(exitCode, exitStatus) { root.finishRun(exitCode) }
  }
}
