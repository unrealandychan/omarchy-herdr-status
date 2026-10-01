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
  property string statusFilter: "all"
  property bool searchActive: false
  property var previousAgentStatuses: ({})

  onStatusFilterChanged: {
    if (selectedIndex >= filteredAgents.length) {
      selectedIndex = Math.max(0, filteredAgents.length - 1)
    }
  }

  readonly property var filteredAgents: {
    var q = root.filterQuery ? root.filterQuery.trim().toLowerCase() : ""
    var filter = root.statusFilter
    var list = root.agents || []
    var out = []
    for (var i = 0; i < list.length; i++) {
      var a = list[i]
      if (!a) continue

      if (filter === "working" && !root.isWorkingStatus(a.status)) continue
      if (filter === "blocked" && !root.isBlockedStatus(a.status)) continue
      if (filter === "done" && !root.isDoneStatus(a.status)) continue
      if (filter === "idle" && !root.isIdleStatus(a.status)) continue

      if (q !== "") {
        var hay = (a.name + " " + a.status + " " + root.statusLabel(a.status) + " " + a.pane_id + " " + (a.title || "") + " " + (a.cwd || "") + " " + (a.session || "")).toLowerCase()
        if (hay.indexOf(q) === -1) continue
      }
      out.push(a)
    }
    return out
  }

  function isBlockedStatus(s) {
    if (!s) return false
    var v = s.toLowerCase()
    return v === "blocked" || v === "waiting" || v === "prompt" || v === "input" || v === "needs_input" || v === "permission" || v === "confirm"
  }

  function isWorkingStatus(s) {
    if (!s) return false
    var v = s.toLowerCase()
    return v === "working" || v === "busy" || v === "running" || v === "thinking" || v === "generating"
  }

  function isDoneStatus(s) {
    if (!s) return false
    var v = s.toLowerCase()
    return v === "done" || v === "completed" || v === "finished"
  }

  function isIdleStatus(s) {
    if (!s) return true
    var v = s.toLowerCase()
    return v === "idle" || v === "ready" || (!isWorkingStatus(v) && !isBlockedStatus(v) && !isDoneStatus(v))
  }

  function statusLabel(s) {
    if (isBlockedStatus(s)) return "needs input"
    if (isWorkingStatus(s)) return "working"
    if (isDoneStatus(s)) return "done"
    if (!s || s.toLowerCase() === "idle" || s.toLowerCase() === "ready") return "ready"
    return s
  }

  function notifyAgentStatus(a) {
    if (!root.notificationsEnabled) return
    var blocked = root.isBlockedStatus(a.status)
    var glyph = blocked ? "󰅚" : "󰄬"
    var urgency = blocked ? "critical" : "normal"
    var headline = (blocked ? "Agent Needs Input: " : "Agent Completed: ") + a.name
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
    if (mins < 60) {
      return mins + "m " + (remSecs < 10 ? "0" : "") + remSecs + "s"
    }
    var hours = Math.floor(mins / 60)
    var remMins = mins % 60
    return hours + "h " + (remMins < 10 ? "0" : "") + remMins + "m"
  }

  onAgentsChanged: {
    if (selectedIndex >= filteredAgents.length) {
      selectedIndex = Math.max(0, filteredAgents.length - 1)
    }

    var nextStatuses = {}
    for (var i = 0; i < agents.length; i++) {
      var a = agents[i]
      var prev = root.previousAgentStatuses[a.pane_id]
      if (prev && root.isWorkingStatus(prev) && (root.isBlockedStatus(a.status) || root.isDoneStatus(a.status))) {
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
    root.statusFilter = "all"
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
        if (root.isWorkingStatus(a.status)) icon = "󱑎"
        else if (root.isBlockedStatus(a.status)) icon = "󰅚"
        else if (root.isDoneStatus(a.status)) icon = "󰄬"
        t += icon + " " + a.name + " [" + root.statusLabel(a.status) + "] · " + a.pane_id + "\n"
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
    var p = targetPane ? String(targetPane) : ""
    var s = (session && session !== "default") ? String(session) : ""
    var args = ["herdr-focus"]
    if (p !== "" || s !== "") {
      args.push(p)
      if (s !== "") {
        args.push(s)
      }
    }
    if (typeof Quickshell !== "undefined" && Quickshell.execDetached) {
      Quickshell.execDetached(args)
    } else if (root.bar && typeof root.bar.execDetached === "function") {
      root.bar.execDetached(args)
    }
    root.close()
  }

  function getFirstActionableAgent() {
    for (var i = 0; i < root.agents.length; i++) {
      if (root.isBlockedStatus(root.agents[i].status)) return root.agents[i]
    }
    for (var j = 0; j < root.agents.length; j++) {
      if (root.isWorkingStatus(root.agents[j].status)) return root.agents[j]
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
          id: pillWorking
          readonly property bool active: root.statusFilter === "working"
          height: Style.space(24)
          width: pillWorkingRow.implicitWidth + Style.space(16)
          radius: Style.space(12)
          color: active ? Qt.rgba(0.2, 0.6, 1.0, 0.4) : (root.workingAgents > 0 ? Qt.rgba(0.2, 0.6, 1.0, 0.2) : (workingMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.05)))
          border.color: active ? Color.accent : (root.workingAgents > 0 ? Color.accent : "transparent")
          border.width: active ? 2 : 1

          Row {
            id: pillWorkingRow
            anchors.centerIn: parent
            spacing: Style.space(4)
            Text { text: "󱑎"; color: Color.accent; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption }
            Text { text: root.workingAgents + " working"; color: (active || root.workingAgents > 0) ? Color.accent : Color.muted; font.pixelSize: Style.font.caption; font.bold: active || root.workingAgents > 0 }
          }

          MouseArea {
            id: workingMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              root.statusFilter = (root.statusFilter === "working" ? "all" : "working")
              root.selectedIndex = 0
            }
          }
        }

        // Blocked Pill
        Rectangle {
          id: pillBlocked
          readonly property bool active: root.statusFilter === "blocked"
          height: Style.space(24)
          width: pillBlockedRow.implicitWidth + Style.space(16)
          radius: Style.space(12)
          color: active ? Qt.rgba(1.0, 0.2, 0.2, 0.45) : (root.blockedAgents > 0 ? Qt.rgba(1.0, 0.2, 0.2, 0.25) : (blockedMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.05)))
          border.color: active ? Color.urgent : (root.blockedAgents > 0 ? Color.urgent : "transparent")
          border.width: active ? 2 : 1

          Row {
            id: pillBlockedRow
            anchors.centerIn: parent
            spacing: Style.space(4)
            Text { text: "󰅚"; color: Color.urgent; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption }
            Text { text: root.blockedAgents + " needs input"; color: (active || root.blockedAgents > 0) ? Color.urgent : Color.muted; font.pixelSize: Style.font.caption; font.bold: active || root.blockedAgents > 0 }
          }

          MouseArea {
            id: blockedMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              root.statusFilter = (root.statusFilter === "blocked" ? "all" : "blocked")
              root.selectedIndex = 0
            }
          }
        }

        // Done Pill
        Rectangle {
          id: pillDone
          readonly property bool active: root.statusFilter === "done"
          height: Style.space(24)
          width: pillDoneRow.implicitWidth + Style.space(16)
          radius: Style.space(12)
          color: active ? Qt.rgba(0.2, 0.8, 0.4, 0.35) : (root.doneAgents > 0 ? Qt.rgba(0.2, 0.8, 0.4, 0.2) : (doneMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.05)))
          border.color: active ? "#a6e3a1" : (root.doneAgents > 0 ? "#a6e3a1" : "transparent")
          border.width: active ? 2 : 1

          Row {
            id: pillDoneRow
            anchors.centerIn: parent
            spacing: Style.space(4)
            Text { text: "󰄬"; color: "#a6e3a1"; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption }
            Text { text: root.doneAgents + " done"; color: (active || root.doneAgents > 0) ? "#a6e3a1" : Color.muted; font.pixelSize: Style.font.caption; font.bold: active || root.doneAgents > 0 }
          }

          MouseArea {
            id: doneMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              root.statusFilter = (root.statusFilter === "done" ? "all" : "done")
              root.selectedIndex = 0
            }
          }
        }

        // Idle Pill
        Rectangle {
          id: pillIdle
          readonly property bool active: root.statusFilter === "idle"
          height: Style.space(24)
          width: pillIdleRow.implicitWidth + Style.space(16)
          radius: Style.space(12)
          color: active ? Qt.rgba(1, 1, 1, 0.2) : (idleMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.05))
          border.color: active ? Color.foreground : "transparent"
          border.width: active ? 2 : 1

          Row {
            id: pillIdleRow
            anchors.centerIn: parent
            spacing: Style.space(4)
            Text { text: "󰌒"; color: active ? Color.foreground : Color.muted; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption }
            Text { text: root.idleAgents + " ready"; color: active ? Color.foreground : Color.muted; font.pixelSize: Style.font.caption; font.bold: active }
          }

          MouseArea {
            id: idleMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              root.statusFilter = (root.statusFilter === "idle" ? "all" : "idle")
              root.selectedIndex = 0
            }
          }
        }
      }

      // ---------- 2.5 Quick Search & Filter Bar ----------
      Rectangle {
        id: searchBarBox
        width: parent.width
        height: Style.space(32)
        radius: Style.space(6)
        color: Qt.rgba(1, 1, 1, 0.05)
        border.color: filterInput.activeFocus ? Color.accent : (searchBoxMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.25) : Qt.rgba(1, 1, 1, 0.1))
        border.width: filterInput.activeFocus ? 2 : 1

        MouseArea {
          id: searchBoxMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.IBeamCursor
          onClicked: {
            filterInput.forceActiveFocus()
          }
        }

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

          Rectangle {
            visible: root.statusFilter !== "all"
            Layout.preferredHeight: Style.space(20)
            Layout.preferredWidth: filterChipRow.implicitWidth + Style.space(12)
            radius: Style.space(10)
            color: {
              if (root.statusFilter === "blocked") return Qt.rgba(1.0, 0.2, 0.2, 0.3)
              if (root.statusFilter === "working") return Qt.rgba(0.2, 0.6, 1.0, 0.3)
              if (root.statusFilter === "done") return Qt.rgba(0.2, 0.8, 0.4, 0.3)
              return Qt.rgba(1, 1, 1, 0.2)
            }

            Row {
              id: filterChipRow
              anchors.centerIn: parent
              spacing: Style.space(4)
              Text {
                text: root.statusFilter === "blocked" ? "needs input" : (root.statusFilter === "idle" ? "ready" : root.statusFilter)
                color: root.bar ? root.bar.foreground : Color.foreground
                font.pixelSize: Style.font.caption * 0.85
                font.bold: true
              }
              Text {
                text: "✕"
                color: Color.muted
                font.pixelSize: Style.font.caption * 0.8
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.statusFilter = "all"
                root.selectedIndex = 0
              }
            }
          }

          Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            TextInput {
              id: filterInput
              anchors.fill: parent
              verticalAlignment: TextInput.AlignVCenter
              selectByMouse: true
              mouseSelectionMode: TextInput.SelectCharacters
              activeFocusOnTab: true
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
                  root.close()
                }
                event.accepted = true
              }
              Keys.onDownPressed: function(event) {
                if (root.filteredAgents.length > 0) {
                  root.selectedIndex = Math.min(root.selectedIndex + 1, root.filteredAgents.length - 1)
                }
                event.accepted = true
              }
              Keys.onUpPressed: function(event) {
                if (root.selectedIndex > 0) {
                  root.selectedIndex--
                }
                event.accepted = true
              }
              Keys.onReturnPressed: function(event) {
                if (root.filteredAgents.length > 0 && root.selectedIndex < root.filteredAgents.length) {
                  var a = root.filteredAgents[root.selectedIndex]
                  root.switchToHerdr(a.pane_id, a.session)
                }
                event.accepted = true
              }

              Text {
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                visible: !filterInput.text && !filterInput.activeFocus
                text: "Filter agents (/ or f)..."
                color: Qt.rgba(1, 1, 1, 0.35)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.IBeamCursor
              visible: !filterInput.activeFocus
              onClicked: {
                filterInput.forceActiveFocus()
              }
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
                root.selectedIndex = 0
                filterInput.forceActiveFocus()
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

        Row {
          visible: root.agents.length > 0 && root.filteredAgents.length === 0
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(6)
          topPadding: Style.space(8)
          bottomPadding: Style.space(8)

          Text {
            text: root.statusFilter !== "all"
              ? "No " + (root.statusFilter === "idle" ? "ready" : (root.statusFilter === "blocked" ? "needs-input" : root.statusFilter)) + " agents."
              : "No agents matching \"" + root.filterQuery + "\"."
            color: Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            text: "Clear filter"
            color: Color.accent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.statusFilter = "all"
                root.filterQuery = ""
                filterInput.text = ""
                root.selectedIndex = 0
              }
            }
          }
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
                if (root.isBlockedStatus(modelData.status)) return Qt.rgba(1.0, 0.25, 0.25, 0.22)
                if (root.isDoneStatus(modelData.status)) return Qt.rgba(0.2, 0.8, 0.4, 0.20)
                if (root.isWorkingStatus(modelData.status)) return Qt.rgba(0.2, 0.6, 1.0, 0.16)
                return Qt.rgba(1, 1, 1, 0.12)
              }
              if (agentMouse.containsMouse) return Qt.rgba(1, 1, 1, 0.08)
              if (root.isBlockedStatus(modelData.status)) return Qt.rgba(1.0, 0.25, 0.25, 0.12)
              if (root.isDoneStatus(modelData.status)) return Qt.rgba(0.2, 0.8, 0.4, 0.08)
              if (root.isWorkingStatus(modelData.status)) return Qt.rgba(0.2, 0.6, 1.0, 0.05)
              return Qt.rgba(1, 1, 1, 0.03)
            }
            border.color: {
              if (isSelected) return Color.accent
              if (root.isBlockedStatus(modelData.status)) return Color.urgent
              if (root.isDoneStatus(modelData.status)) return "#a6e3a1"
              if (root.isWorkingStatus(modelData.status)) return Color.accent
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
                  if (root.isWorkingStatus(modelData.status)) return "󱑎"
                  if (root.isBlockedStatus(modelData.status)) return "󰅚"
                  if (root.isDoneStatus(modelData.status)) return "󰄬"
                  return "󰌒"
                }
                color: {
                  if (root.isBlockedStatus(modelData.status)) return Color.urgent
                  if (root.isWorkingStatus(modelData.status)) return Color.accent
                  if (root.isDoneStatus(modelData.status)) return "#a6e3a1"
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
                    textFormat: Text.PlainText
                    color: root.bar ? root.bar.foreground : Color.foreground
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                    renderType: Text.NativeRendering
                  }

                  Rectangle {
                    Layout.preferredHeight: Style.space(16)
                    Layout.preferredWidth: statusText.implicitWidth + Style.space(10)
                    radius: Style.space(4)
                    color: {
                      if (root.isBlockedStatus(modelData.status)) return Qt.rgba(1, 0.2, 0.2, 0.2)
                      if (root.isWorkingStatus(modelData.status)) return Qt.rgba(0.2, 0.6, 1, 0.2)
                      if (root.isDoneStatus(modelData.status)) return Qt.rgba(0.2, 0.8, 0.4, 0.2)
                      return Qt.rgba(1, 1, 1, 0.1)
                    }

                    Text {
                      id: statusText
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(5)
                      textFormat: Text.PlainText
                      font.features: { "tnum": 1 }
                      readonly property int elapsed: modelData.state_changed_at ? Math.max(0, root.nowSeconds - modelData.state_changed_at) : 0
                      text: root.statusLabel(modelData.status) + (elapsed > 0 ? (" · " + root.formatDuration(elapsed)) : "")
                      color: {
                        if (root.isBlockedStatus(modelData.status)) return Color.urgent
                        if (root.isWorkingStatus(modelData.status)) return Color.accent
                        if (root.isDoneStatus(modelData.status)) return "#a6e3a1"
                        return Color.muted
                      }
                      font.pixelSize: Style.font.caption * 0.9
                      font.bold: root.isBlockedStatus(modelData.status) || root.isDoneStatus(modelData.status)
                    }
                  }
                }

                Text {
                  text: (modelData.session && modelData.session !== "default" ? ("[" + modelData.session + "] ") : "") + (modelData.pane_id ? ("Pane " + modelData.pane_id + " · ") : "") + (modelData.title && modelData.title !== modelData.name ? (modelData.title + " · ") : "") + (modelData.cwd || "~")
                  textFormat: Text.PlainText
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
