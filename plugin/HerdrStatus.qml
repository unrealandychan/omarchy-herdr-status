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
  property var externalAgents: []
  property bool detectExternalAgents: setting("detectExternalAgents", false)
  property int totalAgents: 0
  property int workingAgents: 0
  property int blockedAgents: 0
  property int doneAgents: 0
  property int idleAgents: 0
  property int unknownAgents: 0
  property string badgeText: "󰚩 0"
  property string badgeIcon: "󰚩"
  property string statusColorRole: "muted"
  property bool popupOpen: false
  property int selectedIndex: 0
  property int nowSeconds: Math.floor(Date.now() / 1000)
  property bool notificationsEnabled: setting("notificationsEnabled", true)
  property string filterQuery: ""
  property string statusFilter: "all"
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

      if (filter !== "all" && root.styleFor(a.status).filter !== filter) continue

      if (q !== "") {
        var hay = (a.name + " " + a.status + " " + root.styleFor(a.status).label + " " + a.pane_id + " " + (a.title || "") + " " + (a.cwd || "") + " " + (a.session || "")).toLowerCase()
        if (hay.indexOf(q) === -1) continue
      }
      out.push(a)
    }
    return out
  }

  // The bridge emits canonical statuses (blocked|working|done|idle|unknown); this table is
  // the only place that maps them to presentation. `filter` is the status pill that lists it.
  // `emphasis` scales card tints so attention states stand out; colors follow the theme.
  readonly property var statusStyles: ({
    blocked: { icon: "󰅚", label: "needs input", color: Color.urgent, emphasis: 1.0, bold: true, filter: "blocked" },
    working: { icon: "󱑎", label: "working", color: Color.accent, emphasis: 0.5, bold: false, filter: "working" },
    done: { icon: "󰄬", label: "done", color: root.doneColor, emphasis: 0.8, bold: true, filter: "done" },
    idle: { icon: "󰌒", label: "ready", color: Color.muted, emphasis: 0.25, bold: false, filter: "idle" },
    unknown: { icon: "󰚩", label: "unknown", color: Color.muted, emphasis: 0.25, bold: false, filter: "idle" }
  })

  // Omarchy's Color has no success role; use the theme's green (color2), else the accent.
  property color doneColor: Color.accent

  function loadDoneColor(raw) {
    var match = String(raw || "").match(/^\s*(?:green|color2)\s*=\s*["']?(#[0-9A-Fa-f]{6})/m)
    root.doneColor = match ? match[1] : Color.accent
  }

  FileView {
    id: themeColors
    path: Color.currentThemePath + "/colors.toml"
    printErrors: false
    onLoaded: root.loadDoneColor(text())
    onLoadFailed: root.loadDoneColor("")
  }

  // Theme switches arrive over shell IPC and update Color; re-read the palette with them.
  Connections {
    target: Color
    function onAccentChanged() { themeColors.reload() }
  }

  function roleColor(role) {
    if (role === "urgent") return Color.urgent
    if (role === "accent") return Color.accent
    if (role === "done") return root.doneColor
    if (role === "foreground") return Color.foreground
    return Color.muted
  }

  function statusOf(s) {
    var v = String(s || "").trim().toLowerCase()
    return root.statusStyles && root.statusStyles[v] ? v : "unknown"
  }

  function styleFor(s) {
    return (root.statusStyles || {})[root.statusOf(s)] || { icon: "󰚩", label: "unknown", color: Color.muted, emphasis: 0.25, bold: false, filter: "idle" }
  }

  function notifyAgentStatus(a) {
    if (!root.notificationsEnabled) return
    var blocked = root.statusOf(a.status) === "blocked"
    var glyph = root.styleFor(a.status).icon
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

  onAgentsChanged: {
    // Also fires while the plugin is being created or torn down, when bindings are unset.
    var list = root.agents || []
    var shown = root.filteredAgents || []
    var previous = root.previousAgentStatuses || {}
    if (selectedIndex >= shown.length) {
      selectedIndex = Math.max(0, shown.length - 1)
    }

    // Pane ids repeat across Herdr sessions, so key by session too.
    var nextStatuses = {}
    for (var i = 0; i < list.length; i++) {
      var a = list[i]
      var key = (a.session || "default") + "/" + a.pane_id
      var prev = previous[key]
      var now = root.statusOf(a.status)
      if (prev === "working" && (now === "blocked" || now === "done")) {
        root.notifyAgentStatus(a)
      }
      nextStatuses[key] = now
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

  // The bridge picks the badge's color role (blocked > working > done > ready).
  readonly property bool badgeActive: ["urgent", "accent", "done"].indexOf(root.statusColorRole) !== -1

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
        var style = root.styleFor(a.status)
        t += style.icon + " " + a.name + " [" + style.label + "] · " + a.pane_id + "\n"
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
      root.externalAgents = data.external_agents || []
      if (data.summary) {
        root.totalAgents = data.summary.total || 0
        root.workingAgents = data.summary.working || 0
        root.blockedAgents = data.summary.blocked || 0
        root.doneAgents = data.summary.done || 0
        root.idleAgents = data.summary.idle || 0
        root.unknownAgents = data.summary.unknown || 0
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
      if (root.statusOf(root.agents[i].status) === "blocked") return root.agents[i]
    }
    for (var j = 0; j < root.agents.length; j++) {
      if (root.statusOf(root.agents[j].status) === "working") return root.agents[j]
    }
    if (root.agents.length > 0) return root.agents[0]
    return null
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: bridgeProc
    command: root.detectExternalAgents ? ["herdr-status-bridge", "--detect-external"] : ["herdr-status-bridge"]
    running: true
    stdout: SplitParser {
      onRead: function(line) { root.handleData(line) }
    }
    onExited: function(exitCode, exitStatus) {
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
    active: root.badgeActive
    activeColor: root.roleColor(root.statusColorRole)
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
      id: popupFocusScope
      anchors.fill: parent
      focus: root.popupOpen && (!filterInput || !filterInput.activeFocus)

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
          filterInput.forceActiveFocus()
          event.accepted = true
        } else if (event.key === Qt.Key_R) {
          bridgeProc.running = false
          bridgeProc.running = true
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
              ? (root.totalAgents + " agent" + (root.totalAgents === 1 ? "" : "s"))
              : "Herdr disconnected"
            color: Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            renderType: Text.NativeRendering
          }
        }

        // Close button
        Rectangle {
          Layout.preferredWidth: Style.space(24)
          Layout.preferredHeight: Style.space(24)
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

        Repeater {
          model: [
            { filter: "working", count: root.workingAgents, label: "working", loud: true },
            { filter: "blocked", count: root.blockedAgents, label: "needs input", loud: true },
            { filter: "done", count: root.doneAgents, label: "done", loud: true },
            { filter: "idle", count: root.idleAgents + root.unknownAgents, label: "ready", loud: false }
          ]

          StatusPill {
            required property var modelData
            readonly property var style: root.styleFor(modelData.filter)
            icon: style.icon
            label: modelData.label
            count: modelData.count
            active: root.statusFilter === modelData.filter
            highlightCount: modelData.loud
            tone: modelData.loud ? style.color : (active ? Color.foreground : Color.muted)
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onClicked: {
              root.statusFilter = (root.statusFilter === modelData.filter ? "all" : modelData.filter)
              root.selectedIndex = 0
            }
          }
        }
      }

      // ---------- 2.5 Quick Search & Filter Bar ----------
      RowLayout {
        width: parent.width
        spacing: Style.space(6)

        Rectangle {
          id: statusFilterChip
          visible: root.statusFilter !== "all"
          Layout.preferredHeight: Style.space(26)
          Layout.preferredWidth: filterChipRow.implicitWidth + Style.space(14)
          radius: Style.space(13)
          readonly property color tone: root.styleFor(root.statusFilter).color
          color: Util.alpha(tone, 0.3)
          border.color: tone
          border.width: 1

          Row {
            id: filterChipRow
            anchors.centerIn: parent
            spacing: Style.space(4)
            Text {
              text: root.styleFor(root.statusFilter).label
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            Text {
              text: "✕"
              color: chipMouse.containsMouse ? Color.urgent : Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          MouseArea {
            id: chipMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              root.statusFilter = "all"
              root.selectedIndex = 0
            }
          }
        }

        TextField {
          id: filterInput
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(32)
          placeholderText: "Search agents (/ or f)..."
          text: root.filterQuery
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          foreground: root.bar ? root.bar.foreground : Color.foreground
          accent: Color.accent

          onTextChanged: {
            root.filterQuery = text
            root.selectedIndex = 0
          }

          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              if (text !== "") {
                text = ""
                root.filterQuery = ""
              } else {
                root.close()
              }
              event.accepted = true
            } else if (event.key === Qt.Key_Down) {
              if (root.filteredAgents.length > 0) {
                root.selectedIndex = Math.min(root.selectedIndex + 1, root.filteredAgents.length - 1)
              }
              event.accepted = true
            } else if (event.key === Qt.Key_Up) {
              if (root.selectedIndex > 0) {
                root.selectedIndex--
              }
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              if (root.filteredAgents.length > 0 && root.selectedIndex < root.filteredAgents.length) {
                var a = root.filteredAgents[root.selectedIndex]
                root.switchToHerdr(a.pane_id, a.session)
              }
              event.accepted = true
            }
          }
        }

        Rectangle {
          visible: root.filterQuery !== ""
          Layout.preferredHeight: Style.space(26)
          Layout.preferredWidth: Style.space(26)
          radius: Style.space(13)
          color: clearBtnMouse.containsMouse ? Util.alpha(Color.foreground, 0.15) : Util.alpha(Color.foreground, 0.05)
          border.color: clearBtnMouse.containsMouse ? Color.accent : "transparent"
          border.width: 1

          Text {
            anchors.centerIn: parent
            text: "󰅖"
            color: clearBtnMouse.containsMouse ? Color.accent : Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          MouseArea {
            id: clearBtnMouse
            anchors.fill: parent
            hoverEnabled: true
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

      // Divider line
      Rectangle {
        width: parent.width
        height: 1
        color: Util.alpha(Color.foreground, 0.1)
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
              ? "No " + root.styleFor(root.statusFilter).label + " agents."
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

          AgentCard {
            required property var modelData
            required property int index
            width: parent.width
            agent: modelData
            style: root.styleFor(modelData.status)
            selected: root.selectedIndex === index
            nowSeconds: root.nowSeconds
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            textColor: root.bar ? root.bar.foreground : Color.foreground
            onHovered: root.selectedIndex = index
            onActivated: root.switchToHerdr(modelData.pane_id, modelData.session)
          }
        }

        // Agents running outside Herdr (opt-in): state unknown, nothing to jump to.
        Text {
          visible: root.externalAgents.length > 0
          text: "Outside Herdr"
          color: Color.muted
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
          topPadding: Style.space(4)
        }

        Repeater {
          model: root.externalAgents

          Text {
            required property var modelData
            width: parent.width
            text: "󰚩 " + modelData.name + " · " + modelData.pane_id + " · " + (modelData.cwd || "~")
            textFormat: Text.PlainText
            color: Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
          }
        }
      }

      // Divider line
      Rectangle {
        width: parent.width
        height: 1
        color: Util.alpha(Color.foreground, 0.1)
      }

      // ---------- 4. Footer Button: Switch to Herdr Screen ----------
      Rectangle {
        width: parent.width
        height: Style.space(34)
        radius: Style.space(6)
        color: herdrBtnMouse.containsMouse ? Color.accent : Util.alpha(Color.foreground, 0.08)

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
}
