import QtQuick
import qs.Commons

// A clickable status count in the popup header; `active` while it is the list filter.
Rectangle {
  id: pill

  property string icon: ""
  property string label: ""
  property int count: 0
  property color tone: Color.muted
  property bool active: false
  // Whether a non-zero count alone highlights the pill (off for the quiet "ready" pill).
  property bool highlightCount: true
  property string fontFamily: Style.font.family

  signal clicked()

  readonly property bool lit: active || (highlightCount && count > 0)

  implicitHeight: Style.space(24)
  implicitWidth: row.implicitWidth + Style.space(16)
  radius: height / 2
  color: active
    ? Util.alpha(tone, 0.35)
    : (lit ? Util.alpha(tone, 0.18) : Util.alpha(Color.foreground, mouse.containsMouse ? 0.12 : 0.05))
  border.color: lit ? tone : "transparent"
  border.width: active ? 2 : 1

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(4)

    Text {
      text: pill.icon
      color: pill.tone
      font.family: pill.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      text: pill.count + " " + pill.label
      color: pill.lit ? pill.tone : Color.muted
      font.family: pill.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: pill.lit
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: pill.clicked()
  }
}
