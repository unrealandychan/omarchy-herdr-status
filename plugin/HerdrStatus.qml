import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "arch.herdr-status"

  property bool connected: false
  property var agents: []
  property int totalAgents: 0
  property int workingAgents: 0
  property int blockedAgents: 0
  property int doneAgents: 0
  property int idleAgents: 0
  property string primaryStatus: "idle"
  property string badgeText: "󰚩 0"
  property string badgeIcon: "󰚩"
  property string statusColorRole: "muted"
  property bool popupOpen: false

  function close() {
    root.popupOpen = false
  }

  function closeForPopoutSwitch() {
    root.close()
  }

  function togglePopup() {
    if (root.popupOpen) {
      root.close()
    } else {
      root.popupOpen = true
    }
  }

  onPopupOpenChanged: {
    if (popup && popup.open !== root.popupOpen) {
      popup.open = root.popupOpen
    }
  }

  readonly property bool hasUrgent: blockedAgents > 0
  readonly property bool isWorking: workingAgents > 0
  readonly property bool isDone: doneAgents > 0 && !isWorking && !hasUrgent

  readonly property color widgetActiveColor: hasUrgent
    ? Color.urgent
    : (isWorking ? Color.accent : (isDone ? "#a6e3a1" : Color.foreground))

  readonly property string displayText: root.vertical
    ? (root.badgeIcon + "\n" + root.totalAgents)
    : (root.badgeText)

  readonly property string tooltipDetails: {
    if (root.popupOpen) return ""
    var t = "󰚩 Herdr Agents (" + root.totalAgents + " active)\n"
    t += "───────────────────────────\n"
    if (root.agents.length === 0) {
      t += "No active agents\n"
    } else {
      for (var i = 0; i < root.agents.length; i++) {
        var a = root.agents[i]
        var icon = "󰌒"
        if (a.status === "working") icon = "󱑎"
        else if (a.status === "blocked") icon = "󰅚"
        else if (a.status === "done") icon = "󰄬"
        t += icon + " " + a.name + " [" + a.status + "] · " + a.pane_id + "\n"
      }
    }
    t += "───────────────────────────\n"
    t += "Left-click: Open Summary Panel\nRight-click: Switch to Herdr Screen"
    return t
  }

  function handleData(line) {
    try {
      var data = JSON.parse(line.trim())
      if (!data) return

      root.connected = data.connected === true
      root.agents = data.agents || []
      if (data.summary) {
        root.totalAgents = data.summary.total || 0
        root.workingAgents = data.summary.working || 0
        root.blockedAgents = data.summary.blocked || 0
        root.doneAgents = data.summary.done || 0
        root.idleAgents = data.summary.idle || 0
        root.primaryStatus = data.summary.primary_status || "idle"
        root.badgeText = data.summary.badge_text || "󰚩 0"
        root.badgeIcon = data.summary.badge_icon || "󰚩"
        root.statusColorRole = data.summary.status_color || "muted"
      }
    } catch(e) {
      // ignore
    }
  }

  function switchToHerdr(targetPane) {
    var paneArg = targetPane ? (" '" + targetPane + "'") : ""
    if (root.bar) {
      root.bar.run("herdr-focus" + paneArg)
    } else {
      Quickshell.execDetached(["herdr-focus", targetPane || ""])
    }
    root.close()
  }

  function getFirstActionablePane() {
    for (var i = 0; i < root.agents.length; i++) {
      if (root.agents[i].status === "blocked") return root.agents[i].pane_id
    }
    for (var j = 0; j < root.agents.length; j++) {
      if (root.agents[j].status === "working") return root.agents[j].pane_id
    }
    if (root.agents.length > 0) return root.agents[0].pane_id
    return ""
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: bridgeProc
    command: ["herdr-status-bridge"]
    running: true
    stdout: SplitParser {
      onRead: function(line) { root.handleData(line) }
    }
    onExited: function(exitCode) {
      restartTimer.start()
    }
  }

  Timer {
    id: restartTimer
    interval: 3000
    repeat: false
    onTriggered: {
      if (!bridgeProc.running) {
        bridgeProc.running = true
      }
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.displayText
    fontSize: Style.font.caption
    horizontalMargin: 6
    tooltipText: root.tooltipDetails
    active: root.hasUrgent || root.isWorking || root.isDone
    activeColor: root.widgetActiveColor
    onPressed: function(btn) {
      if (btn === Qt.RightButton) {
        // Right click: jump directly to Herdr screen
        root.switchToHerdr(root.getFirstActionablePane())
      } else {
        // Left click: toggle the summary popup panel
        root.togglePopup()
      }
    }
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    onOpenChanged: {
      if (!open && root.popupOpen) {
        root.popupOpen = false
      }
    }
    contentWidth: popup.fittedContentWidth(Style.space(380))
    contentHeight: popup.fittedContentHeight(panelContent.implicitHeight)

    FocusScope {
      anchors.fill: parent
      focus: root.popupOpen
      Keys.onEscapePressed: function(event) {
        root.close()
        event.accepted = true
      }
    }

    Column {
      id: panelContent
      width: parent.width
      spacing: Style.space(12)

      // ---------- 1. Header: Icon, Title, Status & Close ----------
      RowLayout {
        width: parent.width

        Text {
          text: "󰚩"
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.subtitle
          renderType: Text.NativeRendering
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(2)

          Text {
            text: "Herdr Coding Agents"
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
            renderType: Text.NativeRendering
          }

          Text {
            text: root.connected
              ? (root.totalAgents + " active session" + (root.totalAgents === 1 ? "" : "s"))
              : "Herdr disconnected"
            color: Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            renderType: Text.NativeRendering
          }
        }

        // Close button
        Rectangle {
          width: Style.space(24)
          height: Style.space(24)
          radius: Style.space(4)
          color: closeMouse.containsMouse ? Color.muted : "transparent"

          Text {
            anchors.centerIn: parent
            text: "󰅖"
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          MouseArea {
            id: closeMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.close()
          }
        }
      }

      // ---------- 2. Status Metric Pills ----------
      Row {
        spacing: Style.space(8)
        width: parent.width

        // Working Pill
        Rectangle {
          height: Style.space(24)
          width: Style.space(78)
          radius: Style.space(12)
          color: root.workingAgents > 0 ? Qt.rgba(0.2, 0.6, 1.0, 0.2) : Qt.rgba(1, 1, 1, 0.05)
          border.color: root.workingAgents > 0 ? Color.accent : "transparent"
          border.width: 1

          Row {
            anchors.centerIn: parent
            spacing: Style.space(4)
            Text { text: "󱑎"; color: Color.accent; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption }
            Text { text: root.workingAgents + " working"; color: root.workingAgents > 0 ? Color.accent : Color.muted; font.pixelSize: Style.font.caption; font.bold: root.workingAgents > 0 }
          }
        }

        // Blocked Pill
        Rectangle {
          height: Style.space(24)
          width: Style.space(78)
          radius: Style.space(12)
          color: root.blockedAgents > 0 ? Qt.rgba(1.0, 0.2, 0.2, 0.25) : Qt.rgba(1, 1, 1, 0.05)
          border.color: root.blockedAgents > 0 ? Color.urgent : "transparent"
          border.width: 1

          Row {
            anchors.centerIn: parent
            spacing: Style.space(4)
            Text { text: "󰅚"; color: Color.urgent; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption }
            Text { text: root.blockedAgents + " blocked"; color: root.blockedAgents > 0 ? Color.urgent : Color.muted; font.pixelSize: Style.font.caption; font.bold: root.blockedAgents > 0 }
          }
        }

        // Done Pill
        Rectangle {
          height: Style.space(24)
          width: Style.space(68)
          radius: Style.space(12)
          color: root.doneAgents > 0 ? Qt.rgba(0.2, 0.8, 0.4, 0.2) : Qt.rgba(1, 1, 1, 0.05)
          border.color: root.doneAgents > 0 ? "#a6e3a1" : "transparent"
          border.width: 1

          Row {
            anchors.centerIn: parent
            spacing: Style.space(4)
            Text { text: "󰄬"; color: "#a6e3a1"; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption }
            Text { text: root.doneAgents + " done"; color: root.doneAgents > 0 ? "#a6e3a1" : Color.muted; font.pixelSize: Style.font.caption }
          }
        }

        // Idle Pill
        Rectangle {
          height: Style.space(24)
          width: Style.space(68)
          radius: Style.space(12)
          color: Qt.rgba(1, 1, 1, 0.05)

          Row {
            anchors.centerIn: parent
            spacing: Style.space(4)
            Text { text: "󰌒"; color: Color.muted; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption }
            Text { text: root.idleAgents + " ready"; color: Color.muted; font.pixelSize: Style.font.caption }
          }
        }
      }

      // Divider line
      Rectangle {
        width: parent.width
        height: 1
        color: Qt.rgba(1, 1, 1, 0.1)
      }

      // ---------- 3. Agent List Section ----------
      Column {
        width: parent.width
        spacing: Style.space(8)

        Text {
          visible: root.agents.length === 0
          text: root.connected ? "No coding agents detected." : "Herdr daemon is not running."
          color: Color.muted
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          anchors.horizontalCenter: parent.horizontalCenter
          topPadding: Style.space(8)
          bottomPadding: Style.space(8)
        }

        Repeater {
          model: root.agents

          Rectangle {
            id: agentCard
            required property var modelData
            width: parent.width
            implicitHeight: agentRow.implicitHeight + Style.space(14)
            radius: Style.space(8)
            color: agentMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(1, 1, 1, 0.03)
            border.color: modelData.status === "blocked"
              ? Color.urgent
              : (modelData.status === "working" ? Color.accent : Qt.rgba(1, 1, 1, 0.1))
            border.width: 1

            MouseArea {
              id: agentMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.switchToHerdr(modelData.pane_id)
            }

            RowLayout {
              id: agentRow
              anchors.fill: parent
              anchors.margins: Style.space(8)
              spacing: Style.space(10)

              // Status Icon Indicator
              Text {
                text: {
                  if (modelData.status === "working") return "󱑎"
                  if (modelData.status === "blocked") return "󰅚"
                  if (modelData.status === "done") return "󰄬"
                  return "󰌒"
                }
                color: {
                  if (modelData.status === "blocked") return Color.urgent
                  if (modelData.status === "working") return Color.accent
                  if (modelData.status === "done") return "#a6e3a1"
                  return Color.muted
                }
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                renderType: Text.NativeRendering
              }

              // Details
              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(2)

                RowLayout {
                  spacing: Style.space(6)

                  Text {
                    text: modelData.name
                    color: root.bar ? root.bar.foreground : Color.foreground
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                    renderType: Text.NativeRendering
                  }

                  Rectangle {
                    height: Style.space(16)
                    width: statusText.implicitWidth + Style.space(8)
                    radius: Style.space(4)
                    color: {
                      if (modelData.status === "blocked") return Qt.rgba(1, 0.2, 0.2, 0.2)
                      if (modelData.status === "working") return Qt.rgba(0.2, 0.6, 1, 0.2)
                      if (modelData.status === "done") return Qt.rgba(0.2, 0.8, 0.4, 0.2)
                      return Qt.rgba(1, 1, 1, 0.1)
                    }

                    Text {
                      id: statusText
                      anchors.centerIn: parent
                      text: modelData.status
                      color: {
                        if (modelData.status === "blocked") return Color.urgent
                        if (modelData.status === "working") return Color.accent
                        if (modelData.status === "done") return "#a6e3a1"
                        return Color.muted
                      }
                      font.pixelSize: Style.font.caption * 0.9
                    }
                  }
                }

                Text {
                  text: (modelData.pane_id ? ("Pane " + modelData.pane_id + " · ") : "") + (modelData.cwd || "~")
                  color: Color.muted
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideMiddle
                  Layout.fillWidth: true
                  renderType: Text.NativeRendering
                }
              }

              // Jump / Action Icon
              Text {
                text: "󰞷"
                color: agentMouse.containsMouse ? Color.accent : Color.muted
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }

      // Divider line
      Rectangle {
        width: parent.width
        height: 1
        color: Qt.rgba(1, 1, 1, 0.1)
      }

      // ---------- 4. Footer Button: Switch to Herdr Screen ----------
      Rectangle {
        width: parent.width
        height: Style.space(34)
        radius: Style.space(6)
        color: herdrBtnMouse.containsMouse ? Color.accent : Qt.rgba(1, 1, 1, 0.08)

        Row {
          anchors.centerIn: parent
          spacing: Style.space(8)

          Text {
            text: "󰞷"
            color: herdrBtnMouse.containsMouse ? Color.background : (root.bar ? root.bar.foreground : Color.foreground)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
          }

          Text {
            text: "Switch to Herdr Screen"
            color: herdrBtnMouse.containsMouse ? Color.background : (root.bar ? root.bar.foreground : Color.foreground)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        MouseArea {
          id: herdrBtnMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.switchToHerdr(root.getFirstActionablePane())
        }
      }
    }
  }
}
