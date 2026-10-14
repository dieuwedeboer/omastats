import QtQuick
import qs.Commons
import qs.Ui
import "../Model.js" as Model

Column {
  id: root

  property var service: null
  property var host: null
  property var settings: ({})
  property string temperatureUnit: "Celsius"
  property bool publicIpEnabled: true
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.family

  function flag(key) { return Model.flag(settings, key) }

  readonly property var snap: service ? service.snapshot : ({})
  readonly property var hist: service ? service.history : Model.emptyHistory()
  readonly property color s1: service ? service.series1 : Color.accent
  readonly property color s2: service ? service.series2 : Color.accent
  readonly property color warn: service ? service.warn : Color.urgent
  readonly property color danger: service ? service.danger : Color.urgent

  readonly property var disks: snap.disks || ({})
  readonly property var volumes: Array.isArray(disks.volumes) ? disks.volumes : []
  readonly property var procs: snap.procs || null
  readonly property string source: String(Model.settingValue(settings, "disksSource") || "all")
  readonly property bool singleDisk: source !== "all" && !!(disks.perDisk && disks.perDisk[source])
  readonly property real readRate: singleDisk ? Model.num(disks.perDisk[source].read) : Model.num(disks.read)
  readonly property real writeRate: singleDisk ? Model.num(disks.perDisk[source].write) : Model.num(disks.write)
  readonly property var readHistory: singleDisk && hist.disks && hist.disks[source] ? hist.disks[source].read : (hist.diskRead || [])
  readonly property var writeHistory: singleDisk && hist.disks && hist.disks[source] ? hist.disks[source].write : (hist.diskWrite || [])
  readonly property var readParts: Model.rateParts(readRate)
  readonly property var writeParts: Model.rateParts(writeRate)
  readonly property string sourceModel: {
    if (!singleDisk) return ""
    for (var i = 0; i < volumes.length; i++) if (volumes[i].disk === source && volumes[i].model) return String(volumes[i].model)
    return ""
  }

  readonly property var zfs: disks.zfs || null
  readonly property var datasets: Model.zfsDatasets(zfs)
  readonly property var snapshots: zfs && Array.isArray(zfs.snapshots) ? zfs.snapshots : []
  readonly property real snapshotSpace: Model.zfsSnapshotSpace(zfs)
  readonly property var datasetTotals: {
    var data = 0, snaps = 0, children = 0
    for (var i = 0; i < datasets.length; i++) {
      data += datasets[i].data
      snaps += datasets[i].snapshots
      children += datasets[i].children
    }
    return { data: data, snapshots: snaps, children: children }
  }
  readonly property var mountOf: {
    var out = {}
    var list = zfs && Array.isArray(zfs.datasets) ? zfs.datasets : []
    for (var i = 0; i < list.length; i++) if (list[i] && list[i].mount) out[list[i].name] = list[i].mount
    return out
  }

  function scanDataset(row) {
    if (service && row && row.mount) service.scanDirectory(row.mount, row.mount, false)
  }

  function openVolume(mount) {
    if (!mount) return
    Util.execArgv(["xdg-open", String(mount)])
    if (host && typeof host.close === "function") host.close()
  }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(10)

  Card {
    visible: root.flag("showVolumes")
    foreground: root.foreground
    spacing: Style.space(4)

    Text {
      textFormat: Text.PlainText
      visible: root.volumes.length === 0
      text: "No mounted volumes"
      color: root.foreground
      opacity: 0.5
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Repeater {
      model: root.volumes.length

      delegate: Item {
        id: row
        required property int index
        readonly property var modelData: root.volumes[index] || ({})
        readonly property real fraction: modelData.size > 0 ? modelData.used / modelData.size : 0
        readonly property string tempText: isFinite(Number(modelData.temp)) && modelData.temp !== null
          ? Model.tempText(modelData.temp, root.temperatureUnit) : ""

        width: parent.width
        height: Style.space(34)

        MiniRing {
          id: ring
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          size: Style.space(24)
          thickness: Style.spaceReal(3)
          value: row.fraction
          color: row.fraction >= 0.92 ? root.danger : (row.fraction >= 0.8 ? root.warn : root.s1)
          foreground: root.foreground
        }

        Text {
          textFormat: Text.PlainText
          anchors.centerIn: ring
          text: Math.round(row.fraction * 100)
          color: root.foreground
          opacity: 0.85
          font.family: root.fontFamily
          font.pixelSize: Math.max(7, Style.font.caption - 2)
          font.bold: true
        }

        Column {
          anchors.left: ring.right
          anchors.leftMargin: Style.space(10)
          anchors.right: trailing.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: 0

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: Model.volumeName(row.modelData.mount)
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: Model.bytesText(row.modelData.avail) + " available"
            color: root.foreground
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Column {
          id: trailing
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: 0

          Measure {
            anchors.right: parent.right
            value: Model.bytesParts(row.modelData.size).value
            unit: Model.bytesParts(row.modelData.size).unit
            foreground: root.foreground
            fontFamily: root.fontFamily
            bold: false
            valueOpacity: 0.85
          }

          Text {
            textFormat: Text.PlainText
            anchors.right: parent.right
            text: [row.modelData.fstype, row.tempText].filter(function(v) { return !!v }).join(" · ")
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        MouseArea {
          id: hover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.openVolume(row.modelData.mount)
        }

        Rectangle {
          anchors.fill: parent
          anchors.leftMargin: -Style.space(6)
          anchors.rightMargin: -Style.space(6)
          z: -1
          radius: Style.cornerRadius
          color: hover.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
        }

        PanelToolTip {
          visible: hover.containsMouse
          text: [row.modelData.model, row.modelData.device, row.modelData.mount].filter(function(v) { return !!v }).join("\n") + "\nClick to open in Files"
          fontFamily: root.fontFamily
        }
      }
    }
  }

  Card {
    visible: root.flag("showActivity")
    foreground: root.foreground

    CardHeader {
      visible: root.singleDisk
      title: "Activity"
      detail: root.singleDisk ? root.source + (root.sourceModel ? " · " + root.sourceModel : "") : ""
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Row {
      width: parent.width

      BigStat {
        width: parent.width / 2
        value: root.readParts.value
        unit: root.readParts.unit
        label: "Read"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      BigStat {
        width: parent.width / 2
        value: root.writeParts.value
        unit: root.writeParts.unit
        label: "Write"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }
    }

    MirrorGraph {
      id: graph
      width: parent.width
      height: Style.space(72)
      up: root.readHistory
      down: root.writeHistory
      upColor: root.s2
      downColor: root.s1
      floor: 262144
      midlineColor: Util.alpha(root.foreground, 0.18)
    }

    Legend {
      foreground: root.foreground
      fontFamily: root.fontFamily
      items: [
        { color: root.s2, label: "Read peak", value: Model.rateParts(graph.peakUp).value, unit: Model.rateParts(graph.peakUp).unit },
        { color: root.s1, label: "Write peak", value: Model.rateParts(graph.peakDown).value, unit: Model.rateParts(graph.peakDown).unit }
      ]
    }
  }

  Card {
    visible: root.flag("showDatasets") && root.datasets.length > 0
    foreground: root.foreground
    spacing: Style.space(6)

    CardHeader {
      title: "Datasets"
      detail: root.snapshotSpace > 0 ? Model.bytesText(root.snapshotSpace) + " in snapshots" : ""
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Repeater {
      model: root.datasets.length

      delegate: Item {
        id: dataset
        required property int index
        readonly property var row: root.datasets[index] || ({})
        readonly property bool scannable: !!row.mount

        width: parent.width
        height: Style.space(44)

        Text {
          id: datasetName
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.right: datasetUsed.left
          anchors.rightMargin: Style.space(8)
          anchors.top: parent.top
          text: Model.datasetLabel(dataset.row)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Measure {
          id: datasetUsed
          anchors.right: parent.right
          anchors.verticalCenter: datasetName.verticalCenter
          value: Model.bytesParts(dataset.row.used).value
          unit: Model.bytesParts(dataset.row.used).unit
          foreground: root.foreground
          fontFamily: root.fontFamily
          bold: false
          valueOpacity: 0.85
        }

        Text {
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: datasetName.bottom
          text: [dataset.row.name, Model.bytesText(dataset.row.data) + " data",
            Model.bytesText(dataset.row.snapshots) + " snapshots"].join(" · ")
          color: root.foreground
          opacity: 0.55
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }

        Rectangle {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(2)
          height: Style.space(5)
          radius: height / 2
          color: Util.alpha(root.foreground, 0.08)

          Row {
            height: parent.height

            Rectangle {
              width: parent.parent.width * dataset.row.dataShare
              height: parent.height
              color: root.s1
            }

            Rectangle {
              width: parent.parent.width * dataset.row.snapshotShare
              height: parent.height
              color: root.s2
            }

            Rectangle {
              width: parent.parent.width * dataset.row.childShare
              height: parent.height
              color: Util.alpha(root.foreground, 0.3)
            }
          }
        }

        MouseArea {
          id: datasetHover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: dataset.scannable ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: root.scanDataset(dataset.row)
        }

        Rectangle {
          anchors.fill: parent
          anchors.leftMargin: -Style.space(6)
          anchors.rightMargin: -Style.space(6)
          z: -1
          radius: Style.cornerRadius
          color: datasetHover.containsMouse && dataset.scannable ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
        }

        PanelToolTip {
          visible: datasetHover.containsMouse
          text: [
            dataset.row.name + (dataset.row.mount ? " on " + dataset.row.mount : ", not mounted"),
            "Data: " + Model.bytesText(dataset.row.data),
            "Snapshots: " + Model.bytesText(dataset.row.snapshots),
            dataset.row.children > 0 ? "Child datasets: " + Model.bytesText(dataset.row.children) : "",
            "Compression: " + dataset.row.ratio.toFixed(2) + "x",
            dataset.scannable ? "Click to list its largest directories" : ""
          ].filter(function(v) { return !!v }).join("\n")
          fontFamily: root.fontFamily
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      readonly property int listed: root.zfs && Array.isArray(root.zfs.datasets) ? root.zfs.datasets.length : 0
      visible: !!root.zfs && Model.num(root.zfs.datasetCount) > listed
      width: parent.width
      text: "Showing the largest " + listed + " of " + Model.num(root.zfs ? root.zfs.datasetCount : 0) + " datasets."
      color: root.foreground
      opacity: 0.5
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Legend {
      foreground: root.foreground
      fontFamily: root.fontFamily
      items: [
        { color: root.s1, label: "Data", value: Model.bytesParts(root.datasetTotals.data).value, unit: Model.bytesParts(root.datasetTotals.data).unit },
        { color: root.s2, label: "Snapshots", value: Model.bytesParts(root.datasetTotals.snapshots).value, unit: Model.bytesParts(root.datasetTotals.snapshots).unit }
      ].concat(root.datasetTotals.children > 0 ? [
        { color: Util.alpha(root.foreground, 0.3), label: "Children", value: Model.bytesParts(root.datasetTotals.children).value, unit: Model.bytesParts(root.datasetTotals.children).unit }
      ] : [])
    }
  }

  Card {
    visible: !!root.service && root.service.scanPath !== ""
    foreground: root.foreground

    DirectoryList {
      service: root.service
      host: root.host
      foreground: root.foreground
      fontFamily: root.fontFamily
      barColor: root.s1
    }
  }

  Card {
    visible: root.flag("showSnapshots") && root.snapshots.length > 0
    foreground: root.foreground
    spacing: Style.space(6)

    CardHeader {
      title: "Snapshots"
      detail: root.zfs ? Model.num(root.zfs.snapshotCount) + " · largest by unique size" : ""
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Repeater {
      model: root.snapshots.length

      delegate: Item {
        id: snapshot
        required property int index
        readonly property var item: root.snapshots[index] || ({})
        readonly property string where: root.mountOf[item.dataset] || String(item.dataset || "")

        width: parent.width
        height: Style.space(32)

        Column {
          anchors.left: parent.left
          anchors.right: snapshotUsed.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: 0

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: String(snapshot.item.name || "")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: snapshot.where + " · " + Model.ageText(snapshot.item.creation, root.snap.t) + " ago"
            color: root.foreground
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
          }
        }

        Measure {
          id: snapshotUsed
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          value: Model.bytesParts(snapshot.item.used).value
          unit: Model.bytesParts(snapshot.item.used).unit
          foreground: root.foreground
          fontFamily: root.fontFamily
          bold: false
          valueOpacity: 0.85
        }

        MouseArea {
          id: snapshotHover
          anchors.fill: parent
          hoverEnabled: true
        }

        PanelToolTip {
          visible: snapshotHover.containsMouse
          text: String(snapshot.item.dataset || "") + "@" + String(snapshot.item.name || "")
            + "\nUnique: " + Model.bytesText(snapshot.item.used)
            + "\nRefers to: " + Model.bytesText(snapshot.item.referenced)
            + "\nCreated: " + Qt.formatDateTime(new Date(Model.num(snapshot.item.creation) * 1000), "yyyy-MM-dd hh:mm")
          fontFamily: root.fontFamily
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: "A snapshot's size is what deleting only that snapshot would free. Blocks that several snapshots share count in none of them, so all "
        + Model.num(root.zfs ? root.zfs.snapshotCount : 0) + " add up to "
        + Model.bytesText(root.zfs ? root.zfs.snapshotUsed : 0) + " while snapshots hold "
        + Model.bytesText(root.snapshotSpace) + " in total."
      color: root.foreground
      opacity: 0.5
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  Card {
    visible: root.flag("showProcesses")
    foreground: root.foreground

    ProcessList {
      host: root.host
      items: root.procs ? (root.procs.io || []) : []
      allItems: root.procs ? (root.procs.all || []) : []
      total: root.procs ? Model.num(root.procs.total) : 0
      sortKey: "io"
      columns: [
        { key: "read", kind: "rate", title: "Read" },
        { key: "write", kind: "rate", title: "Write" }
      ]
      columnWidth: Style.space(70)
      emptyText: root.procs ? "No disk activity" : "Measuring…"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }
  }
}
