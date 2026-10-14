import QtQuick
import qs.Commons

// A quiet bold caption that acts as a button, like a process list's
// "Show all".
Text {
  id: root

  property color foreground: Color.popups.text
  property string fontFamily: Style.font.family
  signal activated()

  textFormat: Text.PlainText
  color: foreground
  opacity: mouse.containsMouse ? 0.9 : 0.5
  font.family: fontFamily
  font.pixelSize: Style.font.caption
  font.bold: true

  Behavior on opacity { NumberAnimation { duration: 90 } }

  MouseArea {
    id: mouse
    anchors.fill: parent
    anchors.margins: -Style.space(4)
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated()
  }
}
