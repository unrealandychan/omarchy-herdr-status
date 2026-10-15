import QtQuick
import QtQuick.Layouts
import qs.Commons

// One agent row in the popup: status icon, name, status/elapsed chip, location, jump arrow.
Rectangle {
  id: card

  property var agent: ({})
  // Entry from the widget's statusStyles table: icon, label, color, emphasis, bold.
  property var style: ({})
  property bool selected: false
  property int nowSeconds: 0
  property string fontFamily: Style.font.family
  property color textColor: Color.foreground

  signal activated()
  signal hovered()

  readonly property color tone: style.color || Color.muted
  readonly property real emphasis: style.emphasis || 0.25
  readonly property int elapsed: agent.state_changed_at ? Math.max(0, nowSeconds - agent.state_changed_at) : 0

  function formatDuration(seconds) {
    var s = Math.max(0, Number(seconds) || 0)
    if (s < 60) return s + "s"
    var mins = Math.floor(s / 60)
    var remSecs = s % 60
    if (mins < 60) return mins + "m " + (remSecs < 10 ? "0" : "") + remSecs + "s"
    var hours = Math.floor(mins / 60)
    var remMins = mins % 60
    return hours + "h " + (remMins < 10 ? "0" : "") + remMins + "m"
  }

  implicitHeight: row.implicitHeight + Style.space(14)
  radius: Style.space(8)
  // Urgent statuses carry a stronger tint (emphasis) so they stand out in the list.
  color: selected
    ? Util.alpha(tone, 0.10 + 0.12 * emphasis)
    : (mouse.containsMouse ? Util.alpha(Color.foreground, 0.08) : Util.alpha(tone, 0.12 * emphasis))
  border.color: selected ? Color.accent : (emphasis >= 0.5 ? tone : Util.alpha(Color.foreground, 0.1))
  border.width: selected ? 2 : 1

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: card.hovered()
    onClicked: card.activated()
  }

  RowLayout {
    id: row
    anchors.fill: parent
    anchors.margins: Style.space(8)
    spacing: Style.space(10)

    Text {
      text: card.style.icon || ""
      color: card.tone
      font.family: card.fontFamily
      font.pixelSize: Style.font.body
      renderType: Text.NativeRendering
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.space(2)

      RowLayout {
        spacing: Style.space(6)

        Text {
          text: card.agent.name || ""
          textFormat: Text.PlainText
          color: card.textColor
          font.family: card.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          renderType: Text.NativeRendering
        }

        Rectangle {
          Layout.preferredHeight: Style.space(16)
          Layout.preferredWidth: statusText.implicitWidth + Style.space(10)
          radius: Style.space(4)
          color: Util.alpha(card.tone, 0.2)

          Text {
            id: statusText
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: Style.space(5)
            textFormat: Text.PlainText
            font.features: { "tnum": 1 }
            text: (card.style.label || "") + (card.elapsed > 0 ? (" · " + card.formatDuration(card.elapsed)) : "")
            color: card.tone
            font.family: card.fontFamily
            font.pixelSize: Style.font.caption * 0.9
            font.bold: card.style.bold === true
          }
        }
      }

      Text {
        text: (card.agent.session && card.agent.session !== "default" ? ("[" + card.agent.session + "] ") : "")
          + (card.agent.pane_id ? ("Pane " + card.agent.pane_id + " · ") : "")
          + (card.agent.title && card.agent.title !== card.agent.name ? (card.agent.title + " · ") : "")
          + (card.agent.cwd || "~")
        textFormat: Text.PlainText
        color: Color.muted
        font.family: card.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
        Layout.fillWidth: true
        renderType: Text.NativeRendering
      }
    }

    Text {
      text: "󰞷"
      color: mouse.containsMouse ? Color.accent : Color.muted
      font.family: card.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
