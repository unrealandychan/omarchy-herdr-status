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
  property int selectedIndex: 0
  property int nowSeconds: Math.floor(Date.now() / 1000)
  property bool notificationsEnabled: setting("notificationsEnabled", true)
  property string filterQuery: ""
  property bool searchActive: false
  property var previousAgentStatuses: ({})

  readonly property var filteredAgents: {
    if (!root.filterQuery || root.filterQuery.trim() === "") return root.agents
    var q = root.filterQuery.trim().toLowerCase()
    var out = []
    for (var i = 0; i < root.agents.length; i++) {
      var a = root.agents[i]
      var hay = (a.name + " " + a.status + " " + a.pane_id + " " + (a.title || "") + " " + (a.cwd || "") + " " + (a.session || "")).toLowerCase()
      if (hay.indexOf(q) !== -1) {
        out.push(a)
      }
    }
    return out
  }

  function notifyAgentStatus(a) {
    if (!root.notificationsEnabled) return
    var glyph = a.status === "blocked" ? "󰅚" : "󰄬"
    var urgency = a.status === "blocked" ? "critical" : "normal"
    var headline = (a.status === "blocked" ? "Agent Needs Input: " : "Agent Completed: ") + a.name
    var body = (a.title && a.title !== a.name ? (a.title + " · ") : "") + "Pane " + a.pane_id
    var paneArg = a.pane_id || ""
    var sessArg = a.session && a.session !== "default" ? a.session : ""
    Quickshell.execDetached([
      "omarchy-notification-send",
      "--app-name", "Herdr",
      "-g", glyph,
      "-u", urgency,
      headline,
      body,
      "--exec", "herdr-focus", paneArg, sessArg
    ])
  }

  Timer {
    id: durationTicker
    interval: 1000
    repeat: true
    running: root.popupOpen
    onTriggered: {
      root.nowSeconds = Math.floor(Date.now() / 1000)
    }
  }

  function formatDuration(seconds) {
    var s = Math.max(0, Number(seconds) || 0)
    if (s < 60) return s + "s"
    var mins = Math.floor(s / 60)
    var remSecs = s % 60
    if (mins < 60) return mins + "m " + remSecs + "s"
    var hours = Math.floor(mins / 60)
    var remMins = mins % 60
    return hours + "h " + remMins + "m"
  }

  onAgentsChanged: {
    if (selectedIndex >= filteredAgents.length) {
      selectedIndex = Math.max(0, filteredAgents.length - 1)
    }

    var nextStatuses = {}
    for (var i = 0; i < agents.length; i++) {
      var a = agents[i]
      var prev = root.previousAgentStatuses[a.pane_id]
      if (prev && prev === "working" && (a.status === "blocked" || a.status === "done")) {
        root.notifyAgentStatus(a)
      }
      nextStatuses[a.pane_id] = a.status
    }
    root.previousAgentStatuses = nextStatuses
  }

  // Omarchy Shell panel contract: opened, open(), close(), toggle()
  readonly property bool opened: popupOpen

  function open() {
    root.openPopup()
  }

  function close() {
    root.popupOpen = false
    if (root.bar && typeof root.bar.releasePopout === "function" && root.bar.activePopout === root) {
      root.bar.releasePopout(root)
    }
  }

  function closeForPopoutSwitch() {
    root.close()
  }

  function openPopup() {
    root.selectedIndex = 0
    root.popupOpen = true
    if (root.bar && typeof root.bar.requestPopout === "function") {
      root.bar.requestPopout(root)
    }
  }

  function togglePopup() {
    if (root.popupOpen || (popup && popup.open)) {
      root.close()
    } else {
      root.openPopup()
    }
  }

  function toggle() {
    root.togglePopup()
  }

  function triggerPress(button) {
    if (button === Qt.RightButton) {
      var act = root.getFirstActionableAgent()
      if (act) {
        root.switchToHerdr(act.pane_id, act.session)
      } else {
        root.switchToHerdr("", "")
      }
    } else {
      root.togglePopup()
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

  function switchToHerdr(targetPane, session) {
    var paneArg = targetPane ? (" '" + targetPane + "'") : " ''"
    var sessArg = session && session !== "default" ? (" '" + session + "'") : ""
    if (root.bar) {
      root.bar.run("herdr-focus" + paneArg + sessArg)
    } else {
      Quickshell.execDetached(["herdr-focus", targetPane || "", session || ""])
    }
    root.close()
  }

  function getFirstActionableAgent() {
    for (var i = 0; i < root.agents.length; i++) {
      if (root.agents[i].status === "blocked") return root.agents[i]
    }
    for (var j = 0; j < root.agents.length; j++) {
      if (root.agents[j].status === "working") return root.agents[j]
    }
    if (root.agents.length > 0) return root.agents[0]
    return null
  }

  function getFirstActionablePane() {
    var act = getFirstActionableAgent()
    return act ? act.pane_id : ""
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
      root.triggerPress(btn)
    }
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    onOpenChanged: {
      if (open !== root.popupOpen) {
        root.popupOpen = open
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
      Keys.onUpPressed: function(event) {
        if (root.selectedIndex > 0) root.selectedIndex--
        event.accepted = true
      }
      Keys.onDownPressed: function(event) {
        if (root.selectedIndex < root.filteredAgents.length - 1) root.selectedIndex++
        event.accepted = true
      }
      Keys.onReturnPressed: function(event) {
        if (root.filteredAgents.length > 0 && root.selectedIndex < root.filteredAgents.length) {
          var a = root.filteredAgents[root.selectedIndex]
          root.switchToHerdr(a.pane_id, a.session)
        }
        event.accepted = true
      }
      Keys.onEnterPressed: function(event) {
        if (root.filteredAgents.length > 0 && root.selectedIndex < root.filteredAgents.length) {
          var a = root.filteredAgents[root.selectedIndex]
          root.switchToHerdr(a.pane_id, a.session)
        }
        event.accepted = true
      }
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_J) {
          if (root.selectedIndex < root.filteredAgents.length - 1) root.selectedIndex++
          event.accepted = true
        } else if (event.key === Qt.Key_K) {
          if (root.selectedIndex > 0) root.selectedIndex--
          event.accepted = true
        } else if (event.key === Qt.Key_O) {
          if (root.filteredAgents.length > 0 && root.selectedIndex < root.filteredAgents.length) {
            var a = root.filteredAgents[root.selectedIndex]
            root.switchToHerdr(a.pane_id, a.session)
          }
          event.accepted = true
        } else if (event.key === Qt.Key_Slash || event.key === Qt.Key_F) {
          root.searchActive = true
          filterInput.forceActiveFocus()
          event.accepted = true
        } else if (event.key === Qt.Key_R) {
          bridgeProc.running = false
          bridgeProc.running = true
          event.accepted = true
        }
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

      // ---------- 2.5 Quick Search & Filter Bar ----------
      Rectangle {
        width: parent.width
        height: Style.space(32)
        radius: Style.space(6)
        color: Qt.rgba(1, 1, 1, 0.05)
        border.color: filterInput.activeFocus ? Color.accent : Qt.rgba(1, 1, 1, 0.1)
        border.width: 1

        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: Style.space(8)
          anchors.rightMargin: Style.space(8)
          spacing: Style.space(6)

          Text {
            text: "󰍉"
            color: filterInput.activeFocus ? Color.accent : Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          TextInput {
            id: filterInput
            Layout.fillWidth: true
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            clip: true
            text: root.filterQuery
            onTextChanged: {
              root.filterQuery = text
              root.selectedIndex = 0
            }
            Keys.onEscapePressed: function(event) {
              if (text !== "") {
                text = ""
                root.filterQuery = ""
              } else {
                root.searchActive = false
              }
              event.accepted = true
            }

            Text {
              anchors.fill: parent
              visible: !filterInput.text && !filterInput.activeFocus
              text: "Filter agents (/ or f)..."
              color: Qt.rgba(1, 1, 1, 0.3)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            visible: filterInput.text !== ""
            text: "󰅖"
            color: Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                filterInput.text = ""
                root.filterQuery = ""
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

        Text {
          visible: root.agents.length > 0 && root.filteredAgents.length === 0
          text: "No agents matching \"" + root.filterQuery + "\"."
          color: Color.muted
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          anchors.horizontalCenter: parent.horizontalCenter
          topPadding: Style.space(8)
          bottomPadding: Style.space(8)
        }

        Repeater {
          model: root.filteredAgents

          Rectangle {
            id: agentCard
            required property var modelData
            required property int index
            readonly property bool isSelected: root.selectedIndex === index
            width: parent.width
            implicitHeight: agentRow.implicitHeight + Style.space(14)
            radius: Style.space(8)
            color: {
              if (isSelected) {
                if (modelData.status === "blocked") return Qt.rgba(1.0, 0.25, 0.25, 0.22)
                if (modelData.status === "done") return Qt.rgba(0.2, 0.8, 0.4, 0.20)
                if (modelData.status === "working") return Qt.rgba(0.2, 0.6, 1.0, 0.16)
                return Qt.rgba(1, 1, 1, 0.12)
              }
              if (agentMouse.containsMouse) return Qt.rgba(1, 1, 1, 0.08)
              if (modelData.status === "blocked") return Qt.rgba(1.0, 0.25, 0.25, 0.12)
              if (modelData.status === "done") return Qt.rgba(0.2, 0.8, 0.4, 0.08)
              if (modelData.status === "working") return Qt.rgba(0.2, 0.6, 1.0, 0.05)
              return Qt.rgba(1, 1, 1, 0.03)
            }
            border.color: {
              if (isSelected) return Color.accent
              if (modelData.status === "blocked") return Color.urgent
              if (modelData.status === "done") return "#a6e3a1"
              if (modelData.status === "working") return Color.accent
              return Qt.rgba(1, 1, 1, 0.1)
            }
            border.width: isSelected ? 2 : 1

            MouseArea {
              id: agentMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: root.selectedIndex = index
              onClicked: root.switchToHerdr(modelData.pane_id, modelData.session)
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
                      readonly property int elapsed: modelData.state_changed_at ? Math.max(0, root.nowSeconds - modelData.state_changed_at) : 0
                      text: (modelData.status === "idle" ? "ready" : modelData.status) + (elapsed > 0 ? (" · " + root.formatDuration(elapsed)) : "")
                      color: {
                        if (modelData.status === "blocked") return Color.urgent
                        if (modelData.status === "working") return Color.accent
                        if (modelData.status === "done") return "#a6e3a1"
                        return Color.muted
                      }
                      font.pixelSize: Style.font.caption * 0.9
                      font.bold: modelData.status === "blocked" || modelData.status === "done"
                    }
                  }
                }

                Text {
                  text: (modelData.session && modelData.session !== "default" ? ("[" + modelData.session + "] ") : "") + (modelData.pane_id ? ("Pane " + modelData.pane_id + " · ") : "") + (modelData.title && modelData.title !== modelData.name ? (modelData.title + " · ") : "") + (modelData.cwd || "~")
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
          onClicked: {
            var act = root.getFirstActionableAgent()
            if (act) {
              root.switchToHerdr(act.pane_id, act.session)
            } else {
              root.switchToHerdr("", "")
            }
          }
        }
      }
    }
  }
}
