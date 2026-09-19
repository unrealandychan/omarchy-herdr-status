import QtQuick
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
    var text = "Herdr Agents (" + root.totalAgents + " active):\n"
    if (root.agents.length === 0) {
      text += "  No active agents\n"
    } else {
      for (var i = 0; i < root.agents.length; i++) {
        var a = root.agents[i]
        var icon = "󰌒"
        if (a.status === "working") icon = "󱑎"
        else if (a.status === "blocked") icon = "󰅚"
        else if (a.status === "done") icon = "󰄬"

        text += "  " + icon + " " + a.name + " [" + a.status + "] - " + a.pane_id + " (" + a.cwd + ")\n"
      }
    }
    text += "\nLeft-click: Focus active agent\nRight-click: Open Herdr session"
    return text
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
      // ignore partial json
    }
  }

  function focusAgent() {
    // If an agent is blocked or working, focus that target
    var target = ""
    for (var i = 0; i < root.agents.length; i++) {
      if (root.agents[i].status === "blocked") {
        target = root.agents[i].name || root.agents[i].pane_id
        break
      }
    }
    if (!target) {
      for (var j = 0; j < root.agents.length; j++) {
        if (root.agents[j].status === "working") {
          target = root.agents[j].name || root.agents[j].pane_id
          break
        }
      }
    }
    if (!target && root.agents.length > 0) {
      target = root.agents[0].name || root.agents[0].pane_id
    }

    if (target && root.bar) {
      root.bar.run("herdr agent focus " + target)
    } else if (root.bar) {
      root.bar.run("omarchy-launch-terminal")
    }
  }

  function openTerminal() {
    if (root.bar) {
      root.bar.run("omarchy-launch-terminal")
    }
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
        root.openTerminal()
      } else {
        root.focusAgent()
      }
    }
  }
}
