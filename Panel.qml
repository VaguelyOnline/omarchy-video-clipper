import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Clip.js" as Clip

Panel {
  id: root
  moduleName: "vaguely.video-clipper"
  ipcTarget: "vaguely.video-clipper"
  manageIpc: true

  // The bar host injects `bar`, `moduleName` and `settings` and nothing else,
  // so the queue is looked up through the shell rather than handed in.
  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("vaguely.video-clipper") : null

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------- the draft
  //
  // Everything the user is composing lives here until it is handed to the
  // queue. Text fields write into these on change rather than binding both
  // ways, so typing never fights a binding.
  property string draftUrl: ""
  property string draftDir: ""
  property string draftFilename: ""
  property bool segmentMode: false
  property int segmentRevision: 0
  property bool advancedOpen: false
  property string quality: "best"
  property string container: "mp4"
  property string cookies: "none"
  property int concurrent: 4
  property bool audioOnly: false
  property bool preferH264: true
  property bool accurateCuts: true
  property bool forceContainer: true
  // A site login. The password is held here for the shell session only —
  // there is deliberately no setting for it, so it is never written to disk.
  property string username: ""
  property string password: ""
  property string formError: ""

  readonly property int queueCount: service ? service.queue.count : 0
  readonly property int activeCount: service ? service.activeCount : 0

  function applyDefaults() {
    draftDir = String(setting("outputDir", "~/Videos"))
    quality = String(setting("quality", "best"))
    container = String(setting("container", "mp4"))
    cookies = String(setting("cookiesFrom", "none"))
    concurrent = Number(setting("concurrentFragments", 4))
    audioOnly = setting("audioOnly", false) === true
    preferH264 = setting("preferH264", true) !== false
    accurateCuts = setting("accurateCuts", true) !== false
    forceContainer = setting("forceContainer", true) !== false
    username = String(setting("username", ""))
    if (service) service.notifyOnComplete = setting("notifyOnComplete", true) !== false
  }

  function addSegment() {
    var last = segmentModel.count > 0 ? segmentModel.get(segmentModel.count - 1) : null
    segmentModel.append({ startText: last ? String(last.endText) : "", endText: "" })
    segmentRevision++
  }

  function removeSegment(index) {
    segmentModel.remove(index)
    if (segmentModel.count === 0) addSegment()
    segmentRevision++
  }

  // Reads the segment rows as typed. Returns { segments, error }.
  function collectSegments() {
    var segments = []
    for (var i = 0; i < segmentModel.count; i++) {
      var row = segmentModel.get(i)
      var start = Clip.parseTime(row.startText)
      if (start < 0) return { segments: [], error: "Segment " + (i + 1) + " needs a start time like 01:30" }

      var endText = String(row.endText || "").trim()
      var end = endText === "" ? -1 : Clip.parseTime(endText)
      if (endText !== "" && end < 0)
        return { segments: [], error: "Segment " + (i + 1) + " has an end time that is not a timestamp" }
      if (end >= 0 && end <= start)
        return { segments: [], error: "Segment " + (i + 1) + " ends before it starts" }

      segments.push({ start: start, end: end })
    }
    return { segments: segments, error: "" }
  }

  function submit() {
    if (!service) {
      formError = "The download queue is not running"
      return
    }
    if (!Clip.isProbablyUrl(draftUrl)) {
      formError = "Paste a video URL first"
      return
    }
    if (String(draftDir).trim() === "") {
      formError = "Choose a folder to save into"
      return
    }
    var login = String(username).trim()
    if ((login === "") !== (password === "")) {
      formError = "A login needs both a username and a password"
      advancedOpen = true
      return
    }

    var segments = []
    if (segmentMode) {
      var collected = collectSegments()
      if (collected.error !== "") {
        formError = collected.error
        return
      }
      if (collected.segments.length === 0) {
        formError = "Add at least one segment"
        return
      }
      segments = collected.segments
    }

    formError = ""
    service.enqueue({
      url: String(draftUrl).trim(),
      segments: segments,
      outputDir: String(draftDir).trim(),
      quality: quality,
      container: container,
      filename: String(draftFilename).trim(),
      cookies: cookies,
      concurrent: concurrent,
      audioOnly: audioOnly,
      preferH264: preferH264,
      accurateCuts: accurateCuts,
      forceContainer: forceContainer,
      username: login,
      password: password
    })

    // Clear only what belongs to this download; the options stay put so a
    // second clip from the same source is one paste away.
    draftUrl = ""
    draftFilename = ""
    urlField.text = ""
    filenameField.text = ""
    segmentModel.clear()
    addSegment()
    segmentRevision++
  }

  function pasteUrl() {
    pasteProcess.running = false
    pasteProcess.running = true
  }

  function stateGlyph(state) {
    if (state === "done") return "󰄬"
    if (state === "error") return "󰀪"
    if (state === "cancelled") return "󰅖"
    if (state === "running") return "󰇚"
    return "󰥔"
  }

  function stateColor(state) {
    if (state === "error") return root.urgent
    if (state === "running") return root.foreground
    return root.dim
  }

  function statusLine(job) {
    if (!job) return ""
    if (job.state === "queued")
      return "Waiting · " + Clip.segmentsSummary(Clip.decodeSegments(job.segmentsJson))
    if (job.state === "done")
      return "Saved to " + job.outputDir
    if (job.state === "error")
      return job.error
    if (job.state === "cancelled")
      return "Cancelled"

    if (job.stage === "probe") return "Reading video details…"
    if (job.stage === "merge") return "Combining " + job.detail + " segments"
    if (job.stage === "encode") return "Re-encoding " + job.detail + " segments to " + job.container
    if (job.stage === "postprocess") return job.detail !== "" ? "Processing · " + job.detail : "Processing"
    if (job.stage === "finalize") return "Saving to " + job.outputDir

    var parts = []
    parts.push(job.segTotal > 1 ? "Segment " + job.segIndex + " of " + job.segTotal : "Downloading")
    if (job.positionText !== "") parts.push("at " + job.positionText)
    if (job.speed !== "") parts.push(job.speed)
    if (job.eta !== "") parts.push(job.eta)
    return parts.join(" · ")
  }

  Component.onCompleted: {
    applyDefaults()
    if (segmentModel.count === 0) addSegment()
  }
  onSettingsChanged: applyDefaults()
  onServiceChanged: if (service) service.notifyOnComplete = setting("notifyOnComplete", true) !== false

  ListModel { id: segmentModel }

  Process {
    id: pasteProcess
    command: ["wl-paste", "-n"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var text = String(this.text || "").trim()
        if (text === "") return
        root.draftUrl = text
        urlField.text = text
        root.formError = ""
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.activeCount > 0 ? "󰇚" : "󰆐"
    dimmed: root.activeCount === 0
    tooltipText: root.activeCount > 0
      ? "Video Clipper · " + Math.round(root.service.activePercent) + "% · " + root.activeCount + " in queue"
      : "Video Clipper"
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton) root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: urlField
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(700))

    Item {
      id: keyScope
      anchors.fill: parent
      focus: true
      // Keys reach the focused control first — this is a form, so Tab has to
      // walk the fields and letters have to reach the caret. Only an Escape
      // nothing else wanted closes the panel.
      Keys.priority: Keys.AfterItem
      Keys.onEscapePressed: root.close()

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(10)

          PanelHero {
            width: parent.width
            title: "Video Clipper"
            meta: root.activeCount > 0
              ? root.activeCount + (root.activeCount === 1 ? " job running" : " jobs in the queue")
              : "yt-dlp downloads, whole or in pieces"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "󰆐"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ------------------------------------------------------------ url

          PanelSectionHeader { text: "VIDEO URL"; foreground: root.foreground; fontFamily: root.fontFamily }

          Item {
            width: parent.width
            implicitHeight: urlField.implicitHeight

            TextField {
              id: urlField
              anchors.left: parent.left
              anchors.right: pasteButton.left
              anchors.rightMargin: Style.spacing.md
              foreground: root.foreground
              font.family: root.fontFamily
              placeholderText: "https://…"
              onTextChanged: {
                root.draftUrl = text
                if (root.formError !== "") root.formError = ""
              }
              Keys.onEscapePressed: root.close()
              onAccepted: root.submit()
            }

            PanelActionButton {
              id: pasteButton
              anchors.right: parent.right
              anchors.verticalCenter: urlField.verticalCenter
              iconText: "󰆒"
              tooltipText: "Paste from clipboard"
              foreground: root.foreground
              onClicked: root.pasteUrl()
            }
          }

          // ----------------------------------------------------------- mode

          ButtonGroup {
            width: parent.width
            focusable: false
            foreground: root.foreground
            fontFamily: root.fontFamily
            value: root.segmentMode ? "segments" : "whole"
            options: [
              { value: "whole", label: "Whole video" },
              { value: "segments", label: "Pick segments" }
            ]
            onChanged: function(value) {
              root.segmentMode = value === "segments"
              root.formError = ""
            }
          }

          // ------------------------------------------------------- segments

          Column {
            width: parent.width
            visible: root.segmentMode
            spacing: Style.space(6)

            Repeater {
              model: segmentModel

              delegate: Item {
                id: segmentRow
                required property int index
                required property var model

                width: column.width
                implicitHeight: startField.implicitHeight

                readonly property bool startValid: Clip.parseTime(startField.text) >= 0
                readonly property bool endValid: String(endField.text).trim() === ""
                  || Clip.parseTime(endField.text) >= 0

                Text {
                  id: ordinal
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(18)
                  text: (segmentRow.index + 1) + "."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                TextField {
                  id: startField
                  anchors.left: ordinal.right
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(84)
                  foreground: segmentRow.startValid ? root.foreground : root.urgent
                  accent: segmentRow.startValid ? Color.accent : root.urgent
                  font.family: root.fontFamily
                  placeholderText: "00:00"
                  Component.onCompleted: text = String(segmentRow.model.startText)
                  onTextChanged: {
                    segmentModel.setProperty(segmentRow.index, "startText", text)
                    root.segmentRevision++
                    if (root.formError !== "") root.formError = ""
                  }
                  Keys.onEscapePressed: root.close()
                }

                Text {
                  id: arrow
                  textFormat: Text.PlainText
                  anchors.left: startField.right
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(22)
                  horizontalAlignment: Text.AlignHCenter
                  text: "→"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                TextField {
                  id: endField
                  anchors.left: arrow.right
                  anchors.right: removeButton.left
                  anchors.rightMargin: Style.spacing.md
                  anchors.verticalCenter: parent.verticalCenter
                  foreground: segmentRow.endValid ? root.foreground : root.urgent
                  accent: segmentRow.endValid ? Color.accent : root.urgent
                  font.family: root.fontFamily
                  placeholderText: "end of video"
                  Component.onCompleted: text = String(segmentRow.model.endText)
                  onTextChanged: {
                    segmentModel.setProperty(segmentRow.index, "endText", text)
                    root.segmentRevision++
                    if (root.formError !== "") root.formError = ""
                  }
                  Keys.onEscapePressed: root.close()
                  onAccepted: root.submit()
                }

                PanelActionButton {
                  id: removeButton
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "󰅖"
                  tooltipText: "Remove this segment"
                  foreground: root.foreground
                  hoverColor: root.urgent
                  enabled: segmentModel.count > 1
                  onClicked: root.removeSegment(segmentRow.index)
                }
              }
            }

            Item {
              width: parent.width
              implicitHeight: addButton.implicitHeight

              Button {
                id: addButton
                anchors.left: parent.left
                iconText: "󰐕"
                text: "Add segment"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.addSegment()
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.verticalCenter: addButton.verticalCenter
                text: {
                  root.segmentRevision  // re-read the rows whenever one changes
                  var collected = root.collectSegments()
                  if (collected.error !== "") return ""
                  return segmentModel.count + (segmentModel.count === 1 ? " segment · " : " segments · ")
                    + Clip.totalSegmentText(collected.segments)
                }
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // -------------------------------------------------------- save to

          PanelSectionHeader { text: "SAVE TO"; foreground: root.foreground; fontFamily: root.fontFamily }

          Item {
            width: parent.width
            implicitHeight: dirField.implicitHeight

            TextField {
              id: dirField
              anchors.left: parent.left
              anchors.right: openDirButton.left
              anchors.rightMargin: Style.spacing.md
              foreground: root.foreground
              font.family: root.fontFamily
              placeholderText: "~/Videos"
              Component.onCompleted: text = root.draftDir
              onTextChanged: {
                root.draftDir = text
                if (root.formError !== "") root.formError = ""
              }
              Keys.onEscapePressed: root.close()
            }

            PanelActionButton {
              id: openDirButton
              anchors.right: parent.right
              anchors.verticalCenter: dirField.verticalCenter
              iconText: "󰉋"
              tooltipText: "Open this folder in the file manager"
              foreground: root.foreground
              onClicked: if (root.service) root.service.openDirectory(root.draftDir)
            }
          }

          // ------------------------------------------------------- advanced

          Button {
            width: parent.width
            leftAlign: true
            iconText: root.advancedOpen ? "󰅃" : "󰅀"
            text: "Advanced options"
            foreground: root.dim
            fontFamily: root.fontFamily
            onClicked: root.advancedOpen = !root.advancedOpen
          }

          Column {
            width: parent.width
            visible: root.advancedOpen
            spacing: Style.space(8)

            Row {
              width: parent.width
              spacing: Style.spacing.controlGap

              Dropdown {
                width: (parent.width - Style.spacing.controlGap) / 2
                label: "MAX QUALITY"
                foreground: root.foreground
                fontFamily: root.fontFamily
                value: root.quality
                options: [
                  { value: "best", label: "Best available" },
                  { value: "2160", label: "Up to 2160p" },
                  { value: "1440", label: "Up to 1440p" },
                  { value: "1080", label: "Up to 1080p" },
                  { value: "720", label: "Up to 720p" },
                  { value: "480", label: "Up to 480p" }
                ]
                onChanged: function(value) { root.quality = value }
              }

              Dropdown {
                width: (parent.width - Style.spacing.controlGap) / 2
                label: "CONTAINER"
                foreground: root.foreground
                fontFamily: root.fontFamily
                value: root.container
                options: [
                  { value: "mp4", label: "MP4" },
                  { value: "mkv", label: "MKV" }
                ]
                onChanged: function(value) { root.container = value }
              }
            }

            Row {
              width: parent.width
              spacing: Style.spacing.controlGap

              Dropdown {
                width: (parent.width - Style.spacing.controlGap) / 2
                label: "COOKIES FROM"
                foreground: root.foreground
                fontFamily: root.fontFamily
                value: root.cookies
                options: [
                  { value: "none", label: "No cookies" },
                  { value: "firefox", label: "Firefox" },
                  { value: "chromium", label: "Chromium" },
                  { value: "chrome", label: "Chrome" },
                  { value: "brave", label: "Brave" },
                  { value: "vivaldi", label: "Vivaldi" },
                  { value: "edge", label: "Edge" }
                ]
                onChanged: function(value) { root.cookies = value }
              }

              NumberField {
                width: (parent.width - Style.spacing.controlGap) / 2
                fieldWidth: width
                label: "PARALLEL FRAGMENTS"
                foreground: root.foreground
                fontFamily: root.fontFamily
                from: 1
                to: 16
                value: root.concurrent
                onModified: function(value) { root.concurrent = value }
              }
            }

            TextField {
              id: filenameField
              width: parent.width
              foreground: root.foreground
              font.family: root.fontFamily
              placeholderText: "File name (blank uses the video title)"
              onTextChanged: root.draftFilename = text
              Keys.onEscapePressed: root.close()
            }

            Row {
              width: parent.width
              spacing: Style.spacing.controlGap

              TextField {
                id: usernameField
                width: (parent.width - Style.spacing.controlGap) / 2
                foreground: root.foreground
                font.family: root.fontFamily
                placeholderText: "Site username"
                Component.onCompleted: text = root.username
                onTextChanged: {
                  root.username = text
                  if (root.formError !== "") root.formError = ""
                }
                Keys.onEscapePressed: root.close()
              }

              TextField {
                id: passwordField
                width: (parent.width - Style.spacing.controlGap) / 2
                password: true
                foreground: root.foreground
                font.family: root.fontFamily
                placeholderText: "Password"
                onTextChanged: {
                  root.password = text
                  if (root.formError !== "") root.formError = ""
                }
                Keys.onEscapePressed: root.close()
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Login only works on sites yt-dlp can sign in to (not YouTube — use cookies there). The password is kept in memory for this session and never saved."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: [
                { key: "accurateCuts", label: "Accurate cuts", hint: "Re-encode around segment edges so clips start exactly on time" },
                { key: "preferH264", label: "Prefer H.264 / AAC", hint: "Picks codecs that stitch together without a re-encode" },
                { key: "forceContainer", label: "Always produce the chosen container", hint: "Remux when the site hands back something else" },
                { key: "audioOnly", label: "Audio only", hint: "Save an m4a instead of a video" }
              ]

              delegate: Item {
                id: optionRow
                required property var modelData

                width: column.width
                implicitHeight: Math.max(optionSwitch.implicitHeight, optionText.implicitHeight)

                readonly property bool checked: root[optionRow.modelData.key] === true

                Column {
                  id: optionText
                  anchors.left: parent.left
                  anchors.right: optionSwitch.left
                  anchors.rightMargin: Style.spacing.controlGap
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.spacing.xs

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: optionRow.modelData.label
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: optionRow.modelData.hint
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }

                ToggleSwitch {
                  id: optionSwitch
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  checked: optionRow.checked
                  foreground: root.foreground
                  onToggled: root[optionRow.modelData.key] = !optionRow.checked
                }
              }
            }
          }

          // --------------------------------------------------------- submit

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.formError !== ""
            text: root.formError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Button {
            width: parent.width
            bordered: true
            text: root.segmentMode ? "Queue clip" : "Queue download"
            iconText: "󰇚"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.submit()
          }

          // ---------------------------------------------------------- queue

          PanelSeparator { foreground: root.foreground }

          Item {
            width: parent.width
            implicitHeight: queueHeader.implicitHeight

            PanelSectionHeader {
              id: queueHeader
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.queueCount > 0 ? "QUEUE · " + root.queueCount : "QUEUE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            PanelActionButton {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰆴"
              tooltipText: "Clear finished jobs"
              foreground: root.foreground
              hoverColor: root.urgent
              visible: root.queueCount > 0
              onClicked: if (root.service) root.service.clearFinished()
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.queueCount === 0
            text: "Nothing queued. Downloads run one at a time; queue as many as you like."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.service ? root.service.queue : null

            delegate: Column {
              id: jobRow
              required property int index
              required property var model

              width: column.width
              spacing: Style.spacing.xs

              readonly property bool finished: jobRow.model.state === "done"
                || jobRow.model.state === "error"
                || jobRow.model.state === "cancelled"

              Item {
                width: parent.width
                implicitHeight: Math.max(jobTitle.implicitHeight, jobAction.implicitHeight)

                Text {
                  id: jobGlyph
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(18)
                  text: root.stateGlyph(jobRow.model.state)
                  color: root.stateColor(jobRow.model.state)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  id: jobTitle
                  textFormat: Text.PlainText
                  anchors.left: jobGlyph.right
                  anchors.right: jobPercent.left
                  anchors.rightMargin: Style.spacing.md
                  anchors.verticalCenter: parent.verticalCenter
                  text: jobRow.model.title !== "" ? jobRow.model.title : Clip.shortenUrl(jobRow.model.url)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                Text {
                  id: jobPercent
                  textFormat: Text.PlainText
                  anchors.right: jobAction.left
                  anchors.rightMargin: Style.spacing.md
                  anchors.verticalCenter: parent.verticalCenter
                  visible: jobRow.model.state === "running"
                  text: Math.round(jobRow.model.percent) + "%"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                PanelActionButton {
                  id: jobAction
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: jobRow.finished ? "󰅖" : "󰓛"
                  tooltipText: jobRow.finished ? "Remove from the list" : "Cancel this download"
                  foreground: root.foreground
                  hoverColor: root.urgent
                  onClicked: {
                    if (!root.service) return
                    if (jobRow.finished) root.service.removeJob(jobRow.model.jobId)
                    else root.service.cancel(jobRow.model.jobId)
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                x: Style.space(18)
                width: parent.width - Style.space(18)
                text: root.statusLine(jobRow.model)
                color: jobRow.model.state === "error" ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Rectangle {
                x: Style.space(18)
                width: parent.width - Style.space(18)
                height: Style.space(3)
                radius: height / 2
                visible: jobRow.model.state === "running" || jobRow.model.state === "queued"
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

                Rectangle {
                  width: parent.width * Math.max(0, Math.min(1, jobRow.model.percent / 100))
                  height: parent.height
                  radius: parent.radius
                  color: Color.accent
                  Behavior on width { NumberAnimation { duration: 160 } }
                }
              }

              Row {
                x: Style.space(18)
                spacing: Style.spacing.md
                visible: jobRow.model.state === "done" || jobRow.model.state === "error"

                Button {
                  visible: jobRow.model.state === "done"
                  iconText: "󰉋"
                  text: "Open folder"
                  bordered: true
                  fontSize: Style.font.caption
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: if (root.service) root.service.openDirectory(jobRow.model.outputDir)
                }

                Button {
                  visible: jobRow.model.state === "done"
                  iconText: "󰐊"
                  text: "Play"
                  bordered: true
                  fontSize: Style.font.caption
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: if (root.service) root.service.openFile(jobRow.model.outputPath)
                }

                Button {
                  visible: jobRow.model.state === "error"
                  iconText: "󰑓"
                  text: "Try again"
                  bordered: true
                  fontSize: Style.font.caption
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: if (root.service) root.service.retry(jobRow.model.jobId)
                }
              }

              PanelSeparator {
                foreground: root.foreground
                strength: 0.06
                visible: jobRow.index < root.queueCount - 1
              }
            }
          }
        }
      }
    }
  }
}
