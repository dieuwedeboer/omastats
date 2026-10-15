import QtQuick
import qs.Commons
import qs.Ui
import "../Model.js" as Model

// Largest directories one level under a dataset path, from the service's on
// demand du scan. A row opens the next level down; Up returns towards the
// dataset's mount point, never above it.
Column {
  id: root

  property var service: null
  property var host: null
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.family
  property color barColor: Color.accent
  property int maxRows: 15

  readonly property string path: service ? service.scanPath : ""
  readonly property string rootPath: service ? service.scanRoot : ""
  readonly property bool running: !!service && service.scanRunning
  readonly property var result: service ? service.scanResult : null
  readonly property var entries: result && Array.isArray(result.entries) ? result.entries : []
  readonly property real total: result && result.total !== null ? Model.num(result.total) : 0
  readonly property string parentPath: Model.parentWithin(path, rootPath)
  readonly property real shownSize: {
    var sum = 0
    for (var i = 0; i < entries.length; i++) sum += Model.num(entries[i].size)
    return sum
  }
  readonly property var hidden: {
    var count = Math.max(0, entries.length - maxRows)
    var size = 0
    for (var i = maxRows; i < entries.length; i++) size += Model.num(entries[i].size)
    return { count: count, size: size }
  }
  property real now: Date.now()

  function open(target) {
    if (service && target) service.scanDirectory(target)
  }

  function openInDisktree() {
    if (!path) return
    Util.execArgv(["/usr/bin/disktree", path])
    if (host && typeof host.close === "function") host.close()
  }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(6)

  Timer {
    interval: 1000
    repeat: true
    running: root.running
    onTriggered: root.now = Date.now()
  }

  CardHeader {
    title: "Directories"
    detail: root.running
      ? (root.result ? "Rescanning" : "Scanning") + " · " + Math.max(0, Math.round((root.now - (root.service ? root.service.scanStarted : root.now)) / 1000)) + " s"
      : (root.result && !root.result.failed ? Model.bytesText(root.total) : "")
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Item {
    width: parent.width
    height: Style.space(18)

    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.right: actions.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: root.path
      color: root.foreground
      opacity: 0.7
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideMiddle
    }

    Row {
      id: actions
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(12)

      TextAction {
        visible: root.parentPath !== ""
        text: "Up"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onActivated: root.open(root.parentPath)
      }

      TextAction {
        visible: !root.running
        text: "Rescan"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onActivated: if (root.service) root.service.scanDirectory(root.path, undefined, true)
      }

      TextAction {
        visible: !!root.service && root.service.disktreeAvailable
        text: "Open in disktree"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onActivated: root.openInDisktree()
      }

      TextAction {
        text: "Close"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onActivated: if (root.service) root.service.closeScan()
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    visible: root.running && !root.result
    width: parent.width
    text: "Adding up every file below this directory. A large dataset can take a minute or more."
    color: root.foreground
    opacity: 0.55
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Text {
    textFormat: Text.PlainText
    visible: !!root.result && (root.result.failed || root.entries.length === 0)
    width: parent.width
    text: root.result && root.result.failed ? "This directory could not be read." : "No directories here."
    color: root.foreground
    opacity: 0.5
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  Repeater {
    model: Math.min(root.entries.length, root.maxRows)

    delegate: Item {
      id: dirRow
      required property int index
      readonly property var entry: root.entries[index] || ({})
      readonly property real share: root.total > 0 ? Model.clamp(Model.num(entry.size) / root.total, 0, 1) : 0

      width: parent.width
      height: Style.space(28)

      Text {
        id: dirName
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.right: dirSize.left
        anchors.rightMargin: Style.space(8)
        anchors.top: parent.top
        anchors.topMargin: Style.space(2)
        text: String(dirRow.entry.name || "")
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Measure {
        id: dirSize
        anchors.right: parent.right
        anchors.verticalCenter: dirName.verticalCenter
        value: Model.bytesParts(dirRow.entry.size).value
        unit: Model.bytesParts(dirRow.entry.size).unit
        foreground: root.foreground
        fontFamily: root.fontFamily
        bold: false
        valueOpacity: 0.85
      }

      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Style.space(3)
        height: Style.space(3)
        radius: height / 2
        color: Util.alpha(root.foreground, 0.08)

        Rectangle {
          width: parent.width * dirRow.share
          height: parent.height
          radius: parent.radius
          color: root.barColor
        }
      }

      MouseArea {
        id: dirHover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.open(String(dirRow.entry.path || ""))
      }

      Rectangle {
        anchors.fill: parent
        anchors.leftMargin: -Style.space(6)
        anchors.rightMargin: -Style.space(6)
        z: -1
        radius: Style.cornerRadius
        color: dirHover.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
      }

      PanelToolTip {
        visible: dirHover.containsMouse
        text: String(dirRow.entry.path || "") + "\nClick to list the directories inside"
        fontFamily: root.fontFamily
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    visible: root.hidden.count > 0 || (root.result && !root.result.failed && root.total - root.shownSize - root.hidden.size > 0)
    width: parent.width
    text: {
      var parts = []
      if (root.hidden.count > 0)
        parts.push(root.hidden.count + (root.hidden.count === 1 ? " more directory, " : " more directories, ") + Model.bytesText(root.hidden.size))
      var files = root.total - root.shownSize - root.hidden.size
      if (files > 0) parts.push("files directly here, " + Model.bytesText(files))
      var line = parts.join("; ")
      return line ? line.charAt(0).toUpperCase() + line.slice(1) : ""
    }
    color: root.foreground
    opacity: 0.55
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Text {
    textFormat: Text.PlainText
    visible: !!root.result && !root.result.failed
    width: parent.width
    text: (root.result && root.result.incomplete ? "Some directories could not be read, so these sizes leave them out. " : "")
      + (root.result && root.result.truncated ? "Only the first 20,000 directories are listed. " : "")
      + "Sizes are space on disk, after compression. Datasets mounted below this one are not included."
    color: root.foreground
    opacity: 0.5
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
